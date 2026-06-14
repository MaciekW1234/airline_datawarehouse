// ============================================================
// Module: Azure Data Lake Storage Gen2
// Kontenery: bronze / silver / gold (Medallion) + quarantine
// Architektura wg dokumentu PDF §2.1 i §2.8.6
//   bronze     – surowe pliki źródłowe (CSV/ZIP per źródło)
//   silver     – Apache Parquet po walidacji + standaryzacji
//   gold       – kopie zapasowe / eksporty z Azure SQL
//   quarantine – pliki odrzucone przy walidacji schematu
//                (zmiana struktury źródła → ręczna analiza)
// ============================================================

param location string
param projectPrefix string
param environment string

var storageName = replace('st${projectPrefix}${environment}', '-', '')
var storageNameTrimmed = length(storageName) > 24 ? substring(storageName, 0, 24) : storageName

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageNameTrimmed
  location: location
  kind: 'StorageV2'
  sku: {
    name: 'Standard_LRS'
  }
  properties: {
    isHnsEnabled: true          // Hierarchical Namespace = ADLS Gen2
    accessTier: 'Hot'
    supportsHttpsTrafficOnly: true
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    networkAcls: {
      defaultAction: 'Allow'    // zmień na 'Deny' + VNet rules w prod
    }
  }
  tags: {
    project: 'DWH-Aviation'
    environment: environment
  }
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: storageAccount
  name: 'default'
}

// Medallion Architecture – 3 warstwy + quarantine zone
var containers = ['bronze', 'silver', 'gold', 'quarantine']

resource datalakeContainers 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = [for c in containers: {
  parent: blobService
  name: c
  properties: {
    publicAccess: 'None'
  }
}]

output storageAccountName string = storageAccount.name
output storageAccountId string = storageAccount.id
