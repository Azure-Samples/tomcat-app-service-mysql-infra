param name string
param location string
param resourceToken string
param principalId string
@secure()
param databasePassword string

var appName = '${name}-${resourceToken}'

resource virtualNetwork 'Microsoft.Network/virtualNetworks@2024-01-01' = {
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
        name: 'webapp-subnet'
        properties: {
          addressPrefix: '10.0.1.0/24'
          delegations: [
            {
              name: 'dlg-appServices'
              properties: {
                serviceName: 'Microsoft.Web/serverfarms'
              }
            }
          ]
        }
      }
      {
        name: 'database-subnet'
        properties: {
          addressPrefix: '10.0.2.0/24'
          delegations: [
            {
              name: 'dlg-database'
              properties: {
                serviceName: 'Microsoft.DBforMySQL/flexibleServers'
              }
            }
          ]
          privateEndpointNetworkPolicies: 'Disabled'
        }
      }
      {
        name: 'vault-subnet'
        properties: {
          addressPrefix: '10.0.3.0/24'
          privateEndpointNetworkPolicies: 'Disabled'
        }
      }
    ]
  }
  resource subnetForDb 'subnets' existing = {
    name: 'database-subnet'
  }
  resource subnetForVault 'subnets' existing = {
    name: 'vault-subnet'
  }
  resource subnetForApp 'subnets' existing = {
    name: 'webapp-subnet'
  }
  resource subnetForCache 'subnets' existing = {
    name: 'cache-subnet'
  }
}

// Resources needed to secure Key Vault behind a private endpoint
resource privateDnsZoneKeyVault 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: 'privatelink.vaultcore.azure.net'
  location: 'global'
  resource vnetLink 'virtualNetworkLinks@2020-06-01' = {
    location: 'global'
    name: '${appName}-vaultlink'
    properties: {
      virtualNetwork: {
        id: virtualNetwork.id
      }
      registrationEnabled: false
    }
  }
}
resource vaultPrivateEndpoint 'Microsoft.Network/privateEndpoints@2023-04-01' = {
  name: '${appName}-vault-privateEndpoint'
  location: location
  properties: {
    subnet: {
      id: virtualNetwork::subnetForVault.id
    }
    privateLinkServiceConnections: [
      {
        name: '${appName}-vault-privateEndpoint'
        properties: {
          privateLinkServiceId: keyVault.id
          groupIds: ['vault']
        }
      }
    ]
  }
  resource privateDnsZoneGroup 'privateDnsZoneGroups@2024-01-01' = {
    name: 'default'
    properties: {
      privateDnsZoneConfigs: [
        {
          name: 'vault-config'
          properties: {
            privateDnsZoneId: privateDnsZoneKeyVault.id
          }
        }
      ]
    }
  }
}

// Resources needed to secure Azure Database for MySQL with private DNS zone integration
resource privateDnsZoneDB 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: 'privatelink.mysql.database.azure.com'
  location: 'global'
  dependsOn: [
    virtualNetwork
  ]
  resource privateDnsZoneLinkDB 'virtualNetworkLinks@2020-06-01' = {
    name: '${appName}-dblink'
    location: 'global'
    properties: {
      virtualNetwork: {
        id: virtualNetwork.id
      }
      registrationEnabled: false
    }
  }
}

// Resources needed to secure Redis Cache behind a private endpoint
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
  resource privateDnsZoneGroup 'privateDnsZoneGroups' = {
    name: 'default'
    properties: {
      privateDnsZoneConfigs: [
        {
          name: 'cache-config'
          properties: {
            privateDnsZoneId: privateDnsZoneCache.id
          }
        }
      ]
    }
  }
}
resource privateDnsZoneCache 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: 'privatelink.redis.cache.windows.net'
  location: 'global'
  dependsOn: [
    virtualNetwork
  ]
  resource privateDnsZoneLinkCache 'virtualNetworkLinks@2020-06-01' = {
    name: '${appName}-cachelink'
    location: 'global'
    properties: {
      virtualNetwork: {
        id: virtualNetwork.id
      }
      registrationEnabled: false
    }
  }  
}

// The Key Vault is used to manage SQL database and redis secrets.
// Current user has the admin permissions to configure key vault secrets, but by default doesn't have the permissions to read them.
resource keyVault 'Microsoft.KeyVault/vaults@2022-07-01' = {
  name: '${take(replace(appName, '-', ''), 17)}-vault'
  location: location
  properties: {
    enableRbacAuthorization: true
    tenantId: subscription().tenantId
    sku: { family: 'A', name: 'standard' }
    // Only allow requests from the private endpoint in the VNET.
    publicNetworkAccess: 'Disabled' // To see the secret in the portal, change to 'Enabled' 
    networkAcls: {
      defaultAction: 'Deny' // To see the secret in the portal, change to 'Allow' 
      bypass: 'None' 
    }
  }
}

// Grant the current user with key vault secret user role permissions over the key vault. This lets you inspect the secrets, such as in the portal
// If you remove this section, you can't read the key vault secrets, but the app still has access with its managed identity.
resource keyVaultSecretUserRoleRoleDefinition 'Microsoft.Authorization/roleDefinitions@2018-01-01-preview' existing = {
  scope: subscription()
  name: '4633458b-17de-408a-b874-0445c86b69e6' // The built-in Key Vault Secret User role
}
resource keyVaultSecretUserRoleAssignment 'Microsoft.Authorization/roleAssignments@2020-08-01-preview' = {
  scope: keyVault
  name: guid(resourceGroup().id, principalId, keyVaultSecretUserRoleRoleDefinition.id)
  properties: {
    roleDefinitionId: keyVaultSecretUserRoleRoleDefinition.id
    principalId: principalId
    principalType: 'User'
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

  resource db 'databases@2023-06-30' = {
    name: '${appName}-mysql-database'
  }
  dependsOn: [
    privateDnsZoneDB::privateDnsZoneLinkDB
  ]
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
      linuxFxVersion: 'TOMCAT|10.1-java21' // Set to Java 21, Tomcat 10.1
      vnetRouteAllEnabled: true // Route outbound traffic to the VNET
      ftpsState: 'Disabled'
    }
    serverFarmId: appServicePlan.id
    httpsOnly: true
  }

  // Disable basic authentication for FTP and SCM
  resource ftp 'basicPublishingCredentialsPolicies@2023-12-01' = {
    name: 'ftp'
    properties: {
      allow: false
    }
  }
  resource scm 'basicPublishingCredentialsPolicies@2023-12-01' = {
    name: 'scm'
    properties: {
      allow: false
    }
  }

  // Enable App Service native logs
  resource logs 'config' = {
    name: 'logs'
    properties: {
      applicationLogs: {
        fileSystem: {
          level: 'Information'
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

// Service Connector from the app to the key vault, which generates the connection settings for the App Service app
// The application code doesn't make any direct connections to the key vault, but the setup expedites the managed identity access
// so that the cache connector can be configured with key vault references.
resource vaultConnector 'Microsoft.ServiceLinker/linkers@2024-04-01' = {
  scope: web
  name: 'vaultConnector'
  properties: {
    clientType: 'java'
    targetService: {
      type: 'AzureResource'
      id: keyVault.id
    }
    authInfo: {
      authType: 'systemAssignedIdentity' // Use a system-assigned managed identity. No password is used.
    }
    vNetSolution: {
      type: 'privateLink'
    }
  }
  dependsOn: [
    vaultPrivateEndpoint
  ]
}

// Connector to the MySQL database, which generates the connection string for the App Service app
resource dbConnector 'Microsoft.ServiceLinker/linkers@2024-04-01' = {
  scope: web
  name: 'defaultConnector'
  properties: {
    targetService: {
      type: 'AzureResource'
      id: dbserver::db.id
    }
    authInfo: {
      authType: 'secret'
      name: 'mysqladmin'
      secretInfo: {
        secretType: 'rawValue'
        value: databasePassword
      }
    }
    secretStore: {
      keyVaultId: keyVault.id // Configure secrets as key vault references. No secret is exposed in App Service.
    }
    clientType: 'java'
    vNetSolution: null
  }
}

// Service Connector from the app to the cache, which generates an app setting for the ASP.NET Core application
resource cacheConnector 'Microsoft.ServiceLinker/linkers@2024-04-01' = {
  scope: web
  name: 'RedisConnector'
  properties: {
    clientType: 'dotnet'
    targetService: {
      type: 'AzureResource'
      id:  resourceId('Microsoft.Cache/Redis/Databases', redisCache.name, '0')
    }
    authInfo: {
      authType: 'accessKey'
    }
    secretStore: {
      keyVaultId: keyVault.id // Configure secrets as key vault references. No secret is exposed in App Service.
    }
    vNetSolution: {
      type: 'privateLink'
    }
  }
  dependsOn: [
    cachePrivateEndpoint
  ]
}

resource logAnalyticsWorkspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
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

output CONNECTION_SETTINGS array = map(concat(dbConnector.listConfigurations().configurations, cacheConnector.listConfigurations().configurations, vaultConnector.listConfigurations().configurations), config => config.name)
output WEB_APP_LOG_STREAM string = format('https://portal.azure.com/#@/resource{0}/logStream', web.id)
output WEB_APP_SSH string = format('https://{0}.scm.azurewebsites.net/webssh/host', web.name)
output WEB_APP_CONFIG string = format('https://portal.azure.com/#@/resource{0}/environmentVariablesAppSettings', web.id)
