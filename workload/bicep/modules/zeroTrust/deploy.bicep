targetScope = 'subscription'

// ========== //
// Parameters //
// ========== //

@description('Location where to deploy compute services.')
param location string

@description('AVD workload subscription ID, multiple subscriptions scenario.')
param subscriptionId string

@description('Enables a zero trust configuration on the session host disks.')
param diskZeroTrust bool

@description('AVD Resource Group Name for the service objects.')
param serviceObjectsRgName string

@description('Managed identity for zero trust setup.')
param managedIdentityName string

@description('This value is used to set the expiration date on the disk encryption key.')
param diskEncryptionKeyExpirationInDays int

@description('This value is used to set the expiration date on the disk encryption key.')
param diskEncryptionKeyExpirationInEpoch int

@description('Deploy private endpoints for key vault and storage.')
param deployPrivateEndpointKeyvaultStorage bool

@description('Key vault private endpoint name.')
param ztKvPrivateEndpointName string

@description('Private endpoint subnet resource ID')
param privateEndpointsubnetResourceId string

@description('Tags to be applied to resources')
param tags object

@description('Encryption set name')
param diskEncryptionSetName string

@description('Key vault name')
param ztKvName string

@description('Private DNS zone for key vault private endpoint')
param keyVaultprivateDNSResourceId string

@description('Do not modify, used to set unique value for resource deployment.')
param time string = utcNow()

// =========== //
// Variable declaration //
// =========== //
var varCustomPolicyDefinitions = [
    {
      name: 'AVD-ACC-Zero-Trust-Disable-Managed-Disk-Network-Access'
      deploymentName: 'ZT-Disk-Policy'
      displayName: 'Custom - Zero Trust - Disable Managed Disk Network Access'
      libDefinition: json(loadTextContent('../../../policies/zeroTrust/policyDefinitions/policy-definition-es-vm-disk-zero-trust.json'))
    }
]
// =========== //
// Deployments //
// =========== //
// call on the keyvault.

// Policy Definition for Managed Disk Network Access.
module ztPolicyDefinitions '../../../../carml/1.3.0/Microsoft.Authorization/policyDefinitions/subscription/deploy.bicep' = [for customPolicyDefinition in varCustomPolicyDefinitions: if (diskZeroTrust) {
    name: 'Policy-Defin-${customPolicyDefinition.deploymentName}-${time}'
    params: {
        description: customPolicyDefinition.libDefinition.properties.description
        displayName: customPolicyDefinition.libDefinition.properties.displayName
        location: location
        name: customPolicyDefinition.name
        metadata: customPolicyDefinition.libDefinition.properties.metadata
        mode: customPolicyDefinition.libDefinition.properties.mode
        parameters: customPolicyDefinition.libDefinition.properties.parameters
        policyRule: customPolicyDefinition.libDefinition.properties.policyRule
    }
}]

// Policy Assignment for Managed Disk Network Access.
module ztPolicyAssignment '../../../../carml/1.3.0/Microsoft.Authorization/policyAssignments/subscription/deploy.bicep' = [for (customPolicyDefinition, i) in varCustomPolicyDefinitions: if (diskZeroTrust) {
    name: 'Policy-Assign-${customPolicyDefinition.deploymentName}-${time}' 
    params: {
        name: customPolicyDefinition.libDefinition.name
        displayName: customPolicyDefinition.libDefinition.properties.displayName
        description: customPolicyDefinition.libDefinition.properties.description
        identity: 'SystemAssigned'
        location: location
        policyDefinitionId: diskZeroTrust ? ztPolicyDefinitions[i].outputs.resourceId : ''
        resourceSelectors: [
            {
                name: 'VirtualMachineDisks'
                selectors: [
                    {
                        in: [
                            'Microsoft.Compute/disks'
                        ]
                        kind: 'resourceType'
                    }
                ]
            }
        ]
    }
}]

// User Assigned Identity for Zero Trust.
module ztManagedIdentity '../../../../carml/1.3.0/Microsoft.ManagedIdentity/userAssignedIdentities/deploy.bicep' = {
    scope: resourceGroup('${subscriptionId}', '${serviceObjectsRgName}')
    name: 'ZT-Managed-ID-${time}'
    params: {
        location: location
        name: managedIdentityName
        tags: tags
    }
    dependsOn: [

    ]
}

// Introduce wait for managed identity to be ready.
module ztManagedIdentityWait '../../../../carml/1.3.0/Microsoft.Resources/deploymentScripts/deploy.bicep' = {
    scope: resourceGroup('${subscriptionId}', '${serviceObjectsRgName}')
    name: 'ZT-Mana-Ident-Wait-${time}'
    params: {
        name: 'Managed-Idenity-Wait-${time}'
        location: location
        azPowerShellVersion: '8.3.0'
        cleanupPreference: 'Always'
        timeout: 'PT10M'
        scriptContent: '''
        Write-Host "Start"
        Get-Date
        Start-Sleep -Seconds 60
        Write-Host "Stop"
        Get-Date
        '''
    }
    dependsOn: [
        ztManagedIdentity
    ]
  }

// Policy Remediation Task for Zero Trust.
resource ztPolicyRemediationTask 'Microsoft.PolicyInsights/remediations@2021-10-01' = [for (customPolicyDefinition, i) in varCustomPolicyDefinitions : if (diskZeroTrust) {
    name: 'Policy-Remed-${customPolicyDefinition.deploymentName}-${time}'
    properties: {
        failureThreshold: {
            percentage: 1
          }
          parallelDeployments: 10
          policyAssignmentId: diskZeroTrust ? ztPolicyAssignment[i].outputs.resourceId : ''
          resourceCount: 500
    }
}]

// Role Assignment for Zero Trust.
module ztRoleAssignment01 '../../../../carml/1.3.0/Microsoft.Authorization/roleAssignments/resourceGroup/deploy.bicep' = if (diskZeroTrust) {
    scope: resourceGroup('${subscriptionId}', '${serviceObjectsRgName}')
    name: 'ZT-RoleAssignment-${time}'
    params: {
        principalId: diskZeroTrust ? ztManagedIdentity.outputs.principalId : ''
        roleDefinitionIdOrName: 'Key Vault Crypto Service Encryption User'
        principalType: 'ServicePrincipal'
    }
}

// Role Assignment for Zero Trust.
module ztRoleAssignment02 '../../../../carml/1.3.0/Microsoft.Authorization/roleAssignments/subscription/deploy.bicep' = [for (customPolicyDefinition, i) in varCustomPolicyDefinitions : if (diskZeroTrust) {
    name: 'ZT-RoleAssign-${customPolicyDefinition.deploymentName}-${time}'
    params: {
        location: location
        principalId: diskZeroTrust ? ztPolicyAssignment[i].outputs.principalId : ''
        roleDefinitionIdOrName: 'Disk Pool Operator'
        principalType: 'ServicePrincipal'
    }
}]

// Zero trust key vault.
module ztKeyVault './.bicep/zeroTrustKeyVault.bicep' = if (diskZeroTrust) {
    scope: resourceGroup('${subscriptionId}', '${serviceObjectsRgName}')
    name: 'ZT-Key-Vault-${time}'
    params: {
        location: location
        subscriptionId: subscriptionId
        rgName: serviceObjectsRgName
        kvName: ztKvName
        deployPrivateEndpointKeyvaultStorage: deployPrivateEndpointKeyvaultStorage
        ztKvPrivateEndpointName: ztKvPrivateEndpointName
        privateEndpointsubnetResourceId: privateEndpointsubnetResourceId
        keyVaultprivateDNSResourceId: keyVaultprivateDNSResourceId
        diskEncryptionKeyExpirationInDays: diskEncryptionKeyExpirationInDays
        diskEncryptionKeyExpirationInEpoch: diskEncryptionKeyExpirationInEpoch
        diskEncryptionSetName: diskEncryptionSetName
        ztManagedIdentityResourceId: diskZeroTrust ? ztManagedIdentity.outputs.resourceId : ''
        tags: tags
    }
}

// =========== //
// Outputs //
// =========== //

output ztDiskEncryptionSetResourceId string = diskZeroTrust ? ztKeyVault.outputs.ztDiskEncryptionSetResourceId : ''

