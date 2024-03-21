param name string
param location string
param resourceToken string
param principalId string = ''
@secure()
param databasePassword string

var appName = '${name}-${resourceToken}'

// The Key Vault is for saving the randomly generated password
resource keyVault 'Microsoft.KeyVault/vaults@2022-07-01' = {
  name: '${take(replace(appName, '-', ''), 17)}-vault'
  location: location
  properties: {
    tenantId: subscription().tenantId
    sku: { family: 'A', name: 'standard' }
    accessPolicies: [
      {
        objectId: principalId
        permissions: { secrets: [ 'get', 'list' ] }
        tenantId: subscription().tenantId
      }
    ]
  }
}
resource keyVaultSecret 'Microsoft.KeyVault/vaults/secrets@2022-07-01' = {
  name: 'databasePassword'
  parent: keyVault
  properties: {
    contentType: 'string'
    value: databasePassword
  }
}

resource virtualNetwork 'Microsoft.Network/virtualNetworks@2023-04-01' = {
  location: location
  name: '${appName}Vnet'
  properties: {
    addressSpace: {
      addressPrefixes: ['10.0.0.0/16']
    }
    subnets: [
      {
        name: 'cache-subnet'
        properties: {
          addressPrefix: '10.0.0.0/24'
          privateEndpointNetworkPolicies: 'Disabled'
        }
      }
      {
        name: 'database-subnet'
        properties: {
          delegations: [
            {
              name: 'dlg-database'
              properties: {
                serviceName: 'Microsoft.DBforMySQL/flexibleServers'
              }
            }
          ]
          serviceEndpoints: []
          addressPrefix: '10.0.2.0/24'
        }
      }
      {
        name: 'webapp-subnet'
        properties: {
          delegations: [
            {
              name: 'dlg-appServices'
              properties: {
                serviceName: 'Microsoft.Web/serverfarms'
              }
            }
          ]
          serviceEndpoints: []
          addressPrefix: '10.0.1.0/24'
        }
      }
    ]
  }
  resource subnetForDb 'subnets' existing = {
    name: 'database-subnet'
  }
  resource subnetForApp 'subnets' existing = {
    name: 'webapp-subnet'
  }
  resource subnetForCache 'subnets' existing = {
    name: 'cache-subnet'
  }
}

resource privateDnsZoneDB 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: 'privatelink.mysql.database.azure.com'
  location: 'global'
  dependsOn: [
    virtualNetwork
  ]
}

resource privateDnsZoneLinkDB 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  parent: privateDnsZoneDB
  name: '${appName}-dblink'
  location: 'global'
  properties: {
    virtualNetwork: {
      id: virtualNetwork.id
    }
    registrationEnabled: false
  }
}

resource privateDnsZoneCache 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: 'privatelink.redis.cache.windows.net'
  location: 'global'
  dependsOn: [
    virtualNetwork
  ]
}

resource privateDnsZoneLinkCache 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  parent: privateDnsZoneCache
  name: '${appName}-cachelink'
  location: 'global'
  properties: {
    virtualNetwork: {
      id: virtualNetwork.id
    }
    registrationEnabled: false
  }
}

// The MySQL server is configured to be the minimum pricing tier
resource dbserver 'Microsoft.DBforMySQL/flexibleServers@2023-06-30' = {
  location: location
  name: '${appName}-mysql-server'
  properties: {
    version: '8.0.21'
    administratorLogin: 'mysqladmin'
    administratorLoginPassword: databasePassword
    storage: {
      autoGrow: 'Enabled'
      iops: 700
      storageSizeGB: 20
    }
    backup: {
      backupRetentionDays: 7
      geoRedundantBackup: 'Disabled'
    }
    network: {
      privateDnsZoneResourceId: privateDnsZoneDB.id
      delegatedSubnetResourceId: virtualNetwork::subnetForDb.id
      publicNetworkAccess: 'Disabled'
    }
  }
  sku: {
    name: 'Standard_B1ms'
    tier: 'Burstable'
  }
  dependsOn: [
    privateDnsZoneLinkDB
  ]
}

resource db 'Microsoft.DBforMySQL/flexibleServers/databases@2023-06-30' = {
  parent: dbserver
  name: '${appName}-mysql-database'
}

resource cachePrivateEndpoint 'Microsoft.Network/privateEndpoints@2023-04-01' = {
  name: '${appName}-cache-privateEndpoint'
  location: location
  properties: {
    subnet: {
      id: virtualNetwork::subnetForCache.id
    }
    privateLinkServiceConnections: [
      {
        name: '${appName}-cache-privateEndpoint'
        properties: {
          privateLinkServiceId: redisCache.id
          groupIds: ['redisCache']
        }
      }
    ]
  }
  resource cachePrivateDnsZoneGroup 'privateDnsZoneGroups' = {
    name: 'default'
    properties: {
      privateDnsZoneConfigs: [
        {
          name: 'privatelink-redis-cache-windows-net'
          properties: {
            privateDnsZoneId: privateDnsZoneCache.id
          }
        }
      ]
    }
  }
}

// The Redis cache is configured to the minimum pricing tier
resource redisCache 'Microsoft.Cache/Redis@2023-08-01' = {
  name: '${appName}-cache'
  location: location
  properties: {
    sku: {
      name: 'Basic'
      family: 'C'
      capacity: 0
    }
    redisConfiguration: {}
    enableNonSslPort: false
    redisVersion: '6'
    publicNetworkAccess: 'Disabled'
  }
}

// The App Service plan is configured to the B1 pricing tier
resource appServicePlan 'Microsoft.Web/serverfarms@2022-09-01' = {
  name: '${appName}-plan'
  location: location
  kind: 'linux'
  properties: {
    reserved: true
  }
  sku: {
    name: 'B1'
  }
}

resource web 'Microsoft.Web/sites@2022-09-01' = {
  name: appName
  location: location
  tags: {'azd-service-name': 'web'} // Needed by AZD
  properties: {
    siteConfig: {
      linuxFxVersion: 'TOMCAT|10.1-java17' // Set to Java 17, Tomcat 10.1
      vnetRouteAllEnabled: true // Route outbound traffic to the VNET
      ftpsState: 'Disabled'
    }
    serverFarmId: appServicePlan.id
    httpsOnly: true
  }

  // Enable App Service native logs
  resource logs 'config' = {
    name: 'logs'
    properties: {
      applicationLogs: {
        fileSystem: {
          level: 'Verbose'
        }
      }
      detailedErrorMessages: {
        enabled: true
      }
      failedRequestsTracing: {
        enabled: true
      }
      httpLogs: {
        fileSystem: {
          enabled: true
          retentionInDays: 1
          retentionInMb: 35
        }
      }
    }
  }

  // Enable VNET integration
  resource webappVnetConfig 'networkConfig' = {
    name: 'virtualNetwork'
    properties: {
      subnetResourceId: virtualNetwork::subnetForApp.id
    }
  }
  
  dependsOn: [virtualNetwork]
}

// Connector to the MySQL database, which generates the connection string for the App Service app
resource dbConnector 'Microsoft.ServiceLinker/linkers@2022-05-01' = {
  scope: web
  name: 'defaultConnector'
  properties: {
    targetService: {
      type: 'AzureResource'
      id: db.id
    }
    authInfo: {
      authType: 'secret'
      name: 'mysqladmin'
      secretInfo: {
        secretType: 'rawValue'
        value: databasePassword
      }
    }
    clientType: 'java'
    vNetSolution: null
  }
}

// Connector to the Redis cache, which generates the connection string for the App Service app
resource cacheConnector 'Microsoft.ServiceLinker/linkers@2022-05-01' = {
  scope: web
  name: 'RedisConnector'
  properties: {
    targetService: {
      type: 'AzureResource'
      id:  resourceId('Microsoft.Cache/Redis/Databases', redisCache.name, '0')
    }
    authInfo: {
      authType: 'secret'
    }
    clientType: 'java'
    vNetSolution: {
      type: 'privateLink'
    }
  }
}

resource logAnalyticsWorkspace 'Microsoft.OperationalInsights/workspaces@2020-03-01-preview' = {
  name: '${appName}-workspace'
  location: location
  properties: any({
    retentionInDays: 30
    features: {
      searchVersion: 1
    }
    sku: {
      name: 'PerGB2018'
    }
  })
}

// Enable log shipping from the App Service app to the Log Analytics workspace.
resource webdiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'AllLogs'
  scope: web
  properties: {
    workspaceId: logAnalyticsWorkspace.id
    logs: [
      {
        category: 'AppServiceHTTPLogs'
        enabled: true
      }
      {
        category: 'AppServiceConsoleLogs'
        enabled: true
      }
      {
        category: 'AppServiceAppLogs'
        enabled: true
      }
      {
        category: 'AppServiceAuditLogs'
        enabled: true
      }
      {
        category: 'AppServiceIPSecAuditLogs'
        enabled: true
      }
      {
        category: 'AppServicePlatformLogs'
        enabled: true
      }
    ]
    metrics: [
      {
        category: 'AllMetrics'
        enabled: true
      }
    ]
  }
}

output WEB_URI string = 'https://${web.properties.defaultHostName}'

output CONNECTION_SETTINGS array = [dbConnector.listConfigurations().configurations[0].name, cacheConnector.listConfigurations().configurations[0].name]
output WEB_APP_LOG_STREAM string = format('https://portal.azure.com/#@/resource{0}/logStream', web.id)
output WEB_APP_SSH string = format('https://{0}.scm.azurewebsites.net/webssh/host', web.name)
output WEB_APP_CONFIG string = format('https://portal.azure.com/#@/resource{0}/configuration', web.id)
output AZURE_KEY_VAULT_NAME string = keyVault.name
