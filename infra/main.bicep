// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Linea on Azure — minimum-viable deployment.
//
// Topology:
//   resourceGroup
//     ├─ Log Analytics workspace      (for Container Apps logs)
//     ├─ Storage account              (for Azure Files volumes)
//     │    ├─ file share: server-data (Linea-server's BadgerDB)
//     │    └─ file share: web-data    (Linea-web BFF sessions)
//     ├─ Container Apps managed env   (with both storages attached)
//     ├─ Container App: linea-server  (internal ingress on 8080)
//     └─ Container App: linea-web     (external ingress on 8090)
//
// Both apps run as single-replica (minReplicas=maxReplicas=1)
// because Badger is a single-writer KV store. Public traffic
// hits linea-web only; linea-web's BFF reverse-proxies /api/*
// to linea-server via its internal FQDN.

@description('Azure region for all resources.')
param location string = resourceGroup().location

@description('Prefix used in resource names (lower-case, no dashes for storage).')
@minLength(3)
@maxLength(11)
param namePrefix string = 'linea'

@description('Container image for Linea-server (e.g. ghcr.io/nisarul/linea-server:v0.2.0).')
param lineaServerImage string

@description('Container image for Linea-web (e.g. ghcr.io/nisarul/linea-web:v1.0.0).')
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

@description('Image registry server (e.g. ghcr.io). Empty for public images.')
param registryServer string = 'ghcr.io'

@description('Registry username. Empty for anonymous pulls of public images.')
param registryUsername string = ''

@description('Registry password / token. Empty for anonymous pulls of public images.')
@secure()
param registryPassword string = ''

var storageAccountName = toLower(replace('${namePrefix}st${uniqueString(resourceGroup().id)}', '-', ''))
var logWorkspaceName   = '${namePrefix}-logs'
var envName            = '${namePrefix}-env'
var serverAppName      = '${namePrefix}-server'
var webAppName         = '${namePrefix}-web'
var serverShareName    = 'server-data'
var webShareName       = 'web-data'
var serverStorageName  = 'serverdata'
var webStorageName     = 'webdata'

// ----- Log Analytics -----

resource logs 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: logWorkspaceName
  location: location
  properties: {
    sku: { name: 'PerGB2018' }
    retentionInDays: 30
  }
}

// ----- Storage + file shares -----

resource storage 'Microsoft.Storage/storageAccounts@2024-01-01' = {
  name: storageAccountName
  location: location
  kind: 'StorageV2'
  sku: { name: 'Standard_LRS' }
  properties: {
    allowSharedKeyAccess: true
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
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
    shareQuota: 16
    enabledProtocols: 'SMB'
  }
}

resource webShare 'Microsoft.Storage/storageAccounts/fileServices/shares@2024-01-01' = {
  parent: fileServices
  name: webShareName
  properties: {
    shareQuota: 4
    enabledProtocols: 'SMB'
  }
}

// ----- Container Apps managed environment -----

resource env 'Microsoft.App/managedEnvironments@2024-03-01' = {
  name: envName
  location: location
  properties: {
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: logs.properties.customerId
        sharedKey: listKeys(logs.id, '2023-09-01').primarySharedKey
      }
    }
  }
}

resource serverStorage 'Microsoft.App/managedEnvironments/storages@2024-03-01' = {
  parent: env
  name: serverStorageName
  properties: {
    azureFile: {
      accountName: storage.name
      accountKey: storage.listKeys().keys[0].value
      shareName: serverShareName
      accessMode: 'ReadWrite'
    }
  }
}

resource webStorage 'Microsoft.App/managedEnvironments/storages@2024-03-01' = {
  parent: env
  name: webStorageName
  properties: {
    azureFile: {
      accountName: storage.name
      accountKey: storage.listKeys().keys[0].value
      shareName: webShareName
      accessMode: 'ReadWrite'
    }
  }
}

// ----- Linea-server: internal ingress on 8080 -----

resource serverApp 'Microsoft.App/containerApps@2024-03-01' = {
  name: serverAppName
  location: location
  properties: {
    managedEnvironmentId: env.id
    configuration: {
      activeRevisionsMode: 'Single'
      ingress: {
        external: false
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
          storageType: 'AzureFile'
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

resource webApp 'Microsoft.App/containerApps@2024-03-01' = {
  name: webAppName
  location: location
  properties: {
    managedEnvironmentId: env.id
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
            // Filled in by GH Actions after first deploy (or set to placeholder
            // and update once webApp.fqdn is known on the second deploy).
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
          storageType: 'AzureFile'
          storageName: webStorageName
        }
      ]
      scale: { minReplicas: 1, maxReplicas: 1 }
    }
  }
  dependsOn: [
    webStorage
    serverApp
  ]
}

// ----- Outputs -----

output webUrl string         = 'https://${webApp.properties.configuration.ingress.fqdn}'
output serverInternalUrl string = 'https://${serverApp.properties.configuration.ingress.fqdn}'
output webAppName string     = webApp.name
output serverAppName string  = serverApp.name
output redirectUri string    = 'https://${webApp.properties.configuration.ingress.fqdn}/auth/callback'
output logWorkspaceName string = logs.name
