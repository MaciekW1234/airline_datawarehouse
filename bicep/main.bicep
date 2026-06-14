// ============================================================
// DWH Lotniczy – Azure Infrastructure
// Resource Group + Azure SQL Serverless + ADLS Gen2
// Deploy: az deployment sub create --location polandcentral --template-file main.bicep
// ============================================================

targetScope = 'subscription'

@description('Środowisko: dev / test / prod')
@allowed(['dev', 'test', 'prod'])
param environment string = 'dev'

@description('Lokalizacja zasobów')
param location string = 'polandcentral'

@description('Prefix nazw zasobów')
param projectPrefix string = 'dwh-aviation'

@description('SQL admin login')
param sqlAdminLogin string = 'sqladmin'

@secure()
@description('SQL admin password')
param sqlAdminPassword string

// ============================================================
// Resource Group
// ============================================================
resource rg 'Microsoft.Resources/resourceGroups@2023-07-01' = {
  name: 'rg-${projectPrefix}-${environment}'
  location: location
  tags: {
    project: 'DWH-Aviation'
    environment: environment
    owner: 'FortWise'
  }
}

// ============================================================
// Modules
// ============================================================
module storage 'modules/adls.bicep' = {
  name: 'adls-deployment'
  scope: rg
  params: {
    location: location
    projectPrefix: projectPrefix
    environment: environment
  }
}

module sql 'modules/sql.bicep' = {
  name: 'sql-deployment'
  scope: rg
  params: {
    location: location
    projectPrefix: projectPrefix
    environment: environment
    adminLogin: sqlAdminLogin
    adminPassword: sqlAdminPassword
  }
}

// ============================================================
// Outputs
// ============================================================
output resourceGroupName string = rg.name
output storageAccountName string = storage.outputs.storageAccountName
output sqlServerFqdn string = sql.outputs.sqlServerFqdn
output sqlDatabaseName string = sql.outputs.sqlDatabaseName
