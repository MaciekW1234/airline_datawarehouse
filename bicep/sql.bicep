// ============================================================
// Module: Azure SQL Database – Serverless (General Purpose)
// Auto-pause po 60 min bezczynności (oszczędność kosztów dev)
// ============================================================

param location string
param projectPrefix string
param environment string
param adminLogin string
@secure()
param adminPassword string

var serverName = 'sql-${projectPrefix}-${environment}'
var databaseName = 'db-aviation-gold'

resource sqlServer 'Microsoft.Sql/servers@2023-05-01-preview' = {
  name: serverName
  location: location
  properties: {
    administratorLogin: adminLogin
    administratorLoginPassword: adminPassword
    version: '12.0'
    minimalTlsVersion: '1.2'
    publicNetworkAccess: 'Enabled'   // ustaw 'Disabled' + Private Endpoint w prod
  }
  tags: {
    project: 'DWH-Aviation'
    environment: environment
  }
}

// Firewall – Allow Azure Services (ADF, Synapse)
resource firewallAzureServices 'Microsoft.Sql/servers/firewallRules@2023-05-01-preview' = {
  parent: sqlServer
  name: 'AllowAzureServices'
  properties: {
    startIpAddress: '0.0.0.0'
    endIpAddress: '0.0.0.0'
  }
}

resource sqlDatabase 'Microsoft.Sql/servers/databases@2023-05-01-preview' = {
  parent: sqlServer
  name: databaseName
  location: location
  sku: {
    name: 'GP_S_Gen5'      // Serverless General Purpose
    tier: 'GeneralPurpose'
    family: 'Gen5'
    capacity: 2             // 2 vCores max (skaluje się automatycznie od 0.5)
  }
  properties: {
    collation: 'SQL_Latin1_General_CP1_CI_AS'
    maxSizeBytes: 34359738368  // 32 GB
    autoPauseDelay: 60          // auto-pause po 60 min (dev oszczędność)
    minCapacity: '0.5'
    zoneRedundant: false
    requestedBackupStorageRedundancy: 'Local'
  }
  tags: {
    project: 'DWH-Aviation'
    environment: environment
  }
}

output sqlServerFqdn string = sqlServer.properties.fullyQualifiedDomainName
output sqlServerName string = sqlServer.name
output sqlDatabaseName string = sqlDatabase.name
