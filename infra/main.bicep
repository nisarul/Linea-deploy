// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Linea on Azure — VNet-integrated, Premium NFS file storage.
//
// Why this shape:
//   Linea-server uses BadgerDB; the Linea-web BFF uses BadgerDB for
//   sessions. Badger requires fsync-safe persistent storage and a
//   single writer per data directory. Premium Azure Files NFSv4.1
//   gives us proper POSIX fsync behaviour and low latency.
//
//   NFS file shares cannot be exposed to the public internet, so
//   we VNet-inject the Container Apps environment and restrict the
//   storage account to that subnet via a service endpoint.
//
// Topology:
//   linea-vnet (10.0.0.0/16)
//     └─ aca subnet (10.0.0.0/23)  delegated to Container Apps
//
//   resourceGroup
//     ├─ Log Analytics workspace
//     ├─ Premium FileStorage account     (public access disabled,
//     │     ├─ share: server-data 100Gi   subnet-restricted)
//     │     └─ share: web-data    100Gi
//     ├─ Container Apps managed env      (workload-profiles mode,
//     │     ├─ storage: server-data       VNet-integrated)
//     │     └─ storage: web-data
//     ├─ Container App: linea-server     (internal :8080, 1 replica)
//     └─ Container App: linea-web        (external :8090, 1 replica)
//
// Both apps run as single-replica because Badger is a single-writer
// KV store. Public traffic only hits linea-web; linea-web reverse-
// proxies /api/* to linea-server over the env-internal DNS.

@description('Azure region for all resources.')
param location string = resourceGroup().location

@description('Prefix used in resource names (lower-case).')
@minLength(3)
@maxLength(11)
param namePrefix string = 'linea'

@description('Container image for Linea-server.')
param lineaServerImage string

@description('Container image for Linea-web.')
param lineaWebImage string

@description('Entra ID OIDC issuer URL, e.g. https://login.microsoftonline.com/<tenantId>/v2.0')
param oidcIssuer string

@description('Entra ID app registration client id for Linea-web (BFF, confidential client).')
param lineaWebClientId string

@description('Entra ID expected audience for Linea-server (typically the Linea-web client id).')
param lineaServerAudience string

@description('Linea-web client secret. Stored as a secret in the Container App.')
@secure()
param lineaWebClientSecret string

@description('Image registry server (e.g. ghcr.io). Empty for anonymous public-image pulls.')
param registryServer string = 'ghcr.io'

@description('Registry username. Empty for anonymous pulls of public images.')
param registryUsername string = ''

@description('Registry password / token. Empty for anonymous pulls of public images.')
@secure()
param registryPassword string = ''

@description('Provisioned size (GiB) of each Premium file share. 100 is the Premium minimum.')
@minValue(100)
@maxValue(102400)
param shareSizeGiB int = 100

@description('Expose linea-server with external ingress (still requires a valid OIDC bearer token). Useful for local BFF dev pointing at the Azure server.')
param serverExternalIngress bool = false

// ----- Names -----

var storageAccountName = toLower(replace('${namePrefix}st${uniqueString(resourceGroup().id)}', '-', ''))
var logWorkspaceName   = '${namePrefix}-logs'
var vnetName           = '${namePrefix}-vnet'
var subnetName         = 'aca'
var envName            = '${namePrefix}-env'
var serverAppName      = '${namePrefix}-server'
var webAppName         = '${namePrefix}-web'
var serverShareName    = 'server-data'
var webShareName       = 'web-data'
var serverStorageName  = 'serverdata'
var webStorageName     = 'webdata'

// ----- Networking -----

resource vnet 'Microsoft.Network/virtualNetworks@2024-01-01' = {
  name: vnetName
  location: location
  properties: {
    addressSpace: { addressPrefixes: [ '10.0.0.0/16' ] }
    subnets: [
      {
        name: subnetName
        properties: {
          addressPrefix: '10.0.0.0/23'
          serviceEndpoints: [
            { service: 'Microsoft.Storage', locations: [ location ] }
          ]
          delegations: [
            {
              name: 'aca-delegation'
              properties: { serviceName: 'Microsoft.App/environments' }
            }
          ]
          privateEndpointNetworkPolicies: 'Enabled'
        }
      }
    ]
  }
}

resource acaSubnet 'Microsoft.Network/virtualNetworks/subnets@2024-01-01' existing = {
  parent: vnet
  name: subnetName
}

// ----- Log Analytics -----

resource logs 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: logWorkspaceName
  location: location
  properties: {
    sku: { name: 'PerGB2018' }
    retentionInDays: 30
  }
}

// ----- Premium FileStorage account with NFS shares -----
//
// Premium FileStorage requirements:
//   - kind: FileStorage
//   - sku.name: Premium_LRS / Premium_ZRS
//   - Per-share minimum: 100 GiB (provisioned, not consumed)
//
// NFSv4.1 requirements:
//   - supportsHttpsTrafficOnly = false
//   - allowSharedKeyAccess can be false; NFS auth is by network only
//   - public network access disabled; subnet allow-listed via
//     service endpoint OR private endpoint

resource storage 'Microsoft.Storage/storageAccounts@2024-01-01' = {
  name: storageAccountName
  location: location
  kind: 'FileStorage'
  sku: { name: 'Premium_LRS' }
  properties: {
    supportsHttpsTrafficOnly: false
    allowSharedKeyAccess: false
    publicNetworkAccess: 'Enabled'
    minimumTlsVersion: 'TLS1_2'
    networkAcls: {
      defaultAction: 'Deny'
      bypass: 'AzureServices'
      virtualNetworkRules: [
        { id: acaSubnet.id, action: 'Allow' }
      ]
    }
  }
}

resource fileServices 'Microsoft.Storage/storageAccounts/fileServices@2024-01-01' = {
  parent: storage
  name: 'default'
}

resource serverShare 'Microsoft.Storage/storageAccounts/fileServices/shares@2024-01-01' = {
  parent: fileServices
  name: serverShareName
  properties: {
    enabledProtocols: 'NFS'
    rootSquash: 'NoRootSquash'
    shareQuota: shareSizeGiB
  }
}

resource webShare 'Microsoft.Storage/storageAccounts/fileServices/shares@2024-01-01' = {
  parent: fileServices
  name: webShareName
  properties: {
    enabledProtocols: 'NFS'
    rootSquash: 'NoRootSquash'
    shareQuota: shareSizeGiB
  }
}

// ----- Container Apps managed environment (VNet-integrated) -----

resource env 'Microsoft.App/managedEnvironments@2025-01-01' = {
  name: envName
  location: location
  properties: {
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: logs.properties.customerId
        sharedKey: logs.listKeys().primarySharedKey
      }
    }
    vnetConfiguration: {
      infrastructureSubnetId: acaSubnet.id
      internal: false
    }
    workloadProfiles: [
      {
        name: 'Consumption'
        workloadProfileType: 'Consumption'
      }
    ]
  }
}

// NFS file shares attach via the nfsAzureFile property — no account
// key required; access is mediated entirely by the VNet rule on the
// storage account.

resource serverStorage 'Microsoft.App/managedEnvironments/storages@2025-01-01' = {
  parent: env
  name: serverStorageName
  properties: {
    nfsAzureFile: {
      server: '${storage.name}.file.${environment().suffixes.storage}'
      shareName: '/${storage.name}/${serverShareName}'
      accessMode: 'ReadWrite'
    }
  }
}

resource webStorage 'Microsoft.App/managedEnvironments/storages@2025-01-01' = {
  parent: env
  name: webStorageName
  properties: {
    nfsAzureFile: {
      server: '${storage.name}.file.${environment().suffixes.storage}'
      shareName: '/${storage.name}/${webShareName}'
      accessMode: 'ReadWrite'
    }
  }
}

// ----- Linea-server: internal ingress on 8080 -----

resource serverApp 'Microsoft.App/containerApps@2025-01-01' = {
  name: serverAppName
  location: location
  properties: {
    managedEnvironmentId: env.id
    workloadProfileName: 'Consumption'
    configuration: {
      activeRevisionsMode: 'Single'
      ingress: {
        external: serverExternalIngress
        targetPort: 8080
        transport: 'http'
        traffic: [
          { latestRevision: true, weight: 100 }
        ]
      }
      registries: empty(registryUsername) ? [] : [
        {
          server: registryServer
          username: registryUsername
          passwordSecretRef: 'registry-password'
        }
      ]
      secrets: empty(registryPassword) ? [] : [
        { name: 'registry-password', value: registryPassword }
      ]
    }
    template: {
      revisionSuffix: 'v1'
      containers: [
        {
          name: 'linea-server'
          image: lineaServerImage
          resources: {
            cpu: json('0.5')
            memory: '1Gi'
          }
          env: [
            { name: 'LINEA_ADDR',           value: ':8080' }
            { name: 'LINEA_DATA_DIR',       value: '/data' }
            { name: 'LINEA_OIDC_ISSUER',    value: oidcIssuer }
            { name: 'LINEA_OIDC_AUDIENCE',  value: lineaServerAudience }
          ]
          volumeMounts: [
            { volumeName: 'data', mountPath: '/data' }
          ]
          probes: [
            { type: 'Liveness',  httpGet: { path: '/healthz', port: 8080 }, periodSeconds: 30 }
            { type: 'Readiness', httpGet: { path: '/readyz',  port: 8080 }, periodSeconds: 10 }
          ]
        }
      ]
      volumes: [
        {
          name: 'data'
          storageType: 'NfsAzureFile'
          storageName: serverStorageName
        }
      ]
      scale: { minReplicas: 1, maxReplicas: 1 }
    }
  }
  dependsOn: [
    serverStorage
  ]
}

// ----- Linea-web: external ingress on 8090 -----

resource webApp 'Microsoft.App/containerApps@2025-01-01' = {
  name: webAppName
  location: location
  properties: {
    managedEnvironmentId: env.id
    workloadProfileName: 'Consumption'
    configuration: {
      activeRevisionsMode: 'Single'
      ingress: {
        external: true
        targetPort: 8090
        transport: 'http'
        traffic: [
          { latestRevision: true, weight: 100 }
        ]
      }
      registries: empty(registryUsername) ? [] : [
        {
          server: registryServer
          username: registryUsername
          passwordSecretRef: 'registry-password'
        }
      ]
      secrets: concat(
        [
          { name: 'oidc-client-secret', value: lineaWebClientSecret }
        ],
        empty(registryPassword) ? [] : [
          { name: 'registry-password', value: registryPassword }
        ]
      )
    }
    template: {
      revisionSuffix: 'v1'
      containers: [
        {
          name: 'linea-web'
          image: lineaWebImage
          resources: {
            cpu: json('0.25')
            memory: '0.5Gi'
          }
          env: [
            { name: 'LINEA_BFF_ADDR',          value: ':8090' }
            { name: 'LINEA_BFF_COOKIE_SECURE', value: 'true' }
            { name: 'LINEA_BFF_SESSION_DIR',   value: '/data/sessions' }
            { name: 'LINEA_BFF_UPSTREAM_URL',  value: 'https://${serverApp.properties.configuration.ingress.fqdn}' }
            { name: 'LINEA_OIDC_ISSUER',       value: oidcIssuer }
            { name: 'LINEA_OIDC_CLIENT_ID',    value: lineaWebClientId }
            { name: 'LINEA_OIDC_CLIENT_SECRET', secretRef: 'oidc-client-secret' }
            { name: 'LINEA_OIDC_REDIRECT_URL', value: 'https://${webAppName}.${env.properties.defaultDomain}/auth/callback' }
            { name: 'LINEA_BFF_POST_LOGIN_URL', value: '/' }
          ]
          volumeMounts: [
            { volumeName: 'data', mountPath: '/data' }
          ]
          probes: [
            { type: 'Liveness',  httpGet: { path: '/healthz', port: 8090 }, periodSeconds: 30 }
            { type: 'Readiness', httpGet: { path: '/readyz',  port: 8090 }, periodSeconds: 10 }
          ]
        }
      ]
      volumes: [
        {
          name: 'data'
          storageType: 'NfsAzureFile'
          storageName: webStorageName
        }
      ]
      scale: { minReplicas: 1, maxReplicas: 1 }
    }
  }
  dependsOn: [
    webStorage
  ]
}

// ----- Outputs -----

output webUrl string             = 'https://${webApp.properties.configuration.ingress.fqdn}'
output serverInternalUrl string  = 'https://${serverApp.properties.configuration.ingress.fqdn}'
output webAppName string         = webApp.name
output serverAppName string      = serverApp.name
output redirectUri string        = 'https://${webApp.properties.configuration.ingress.fqdn}/auth/callback'
output logWorkspaceName string   = logs.name
output storageAccountName string = storage.name
output vnetName string           = vnet.name
