// CKEditor Cloud Services (CS) environment recovery.
//
// Regenerates CKEDITOR_SERVER_CONFIG for a deployment: for each tenant
// environment it rotates the API secret and token-endpoint access key against
// the CKE CS environments API, then prints a fresh base64-encoded
// CKEDITOR_SERVER_CONFIG value.
//
// Use this when CKEDITOR_SERVER_CONFIG has been lost, or has drifted out of
// sync with the CKE environments, for example after restoring data into a new
// deployment, or if the ckeditor:environment:migration command was run outside
// of an update. It rotates live secrets against CKE's cloud, so run it only as
// part of a controlled migration or recovery.
//
// Run it inside a CKEditor (CS) container:
//
//   node recovery_script.js
//
// If a tenant has more than one environment, pass the mapping explicitly:
//
//   node recovery_script.js TENANT_CUID=ENVIRONMENT_ID [TENANT_CUID=ENVIRONMENT_ID ...]
//
// Set the base64 value it prints as CKEDITOR_SERVER_CONFIG on the deployment
// and restart CKEditor so the new value takes effect.

const crypto = require('crypto');

const generateHex = (size) =>
    [...Array(size)].map(() => Math.floor(Math.random() * 16).toString(16)).join('');

const createdAtSort = (a, b) => {
    if (a.createdAt < b.createdAt) {
        return -1;
    }
    if (a.createdAt > b.createdAt) {
        return 1;
    }
    return 0;
};

async function callApi(method, path, data) {
    const baseURL = `http://localhost:8000`;

    const timestamp = Date.now();
    const signature = generateSignature(method, path, timestamp, data);

    const headers = {
        'X-CS-Signature': signature,
        'X-CS-Timestamp': timestamp,
        'Content-Type': 'application/json',
    };

    const options = {
        method,
        headers,
    };

    if (Object.keys(data || {}).length) {
        options.body = JSON.stringify(data);
    }

    console.log(`REQUEST: ${method} ${baseURL}${path}`);
    const response = await fetch(`${baseURL}${path}`, options);

    return { data: method === 'GET' ? await response.json() : undefined, status: response.status };
}

function generateSignature(method, path, timestamp, body) {
    const apiSecret = process.env.ENVIRONMENTS_MANAGEMENT_SECRET_KEY;

    const hmac = crypto.createHmac('SHA256', apiSecret);

    hmac.update(`${method.toUpperCase()}${path}${timestamp}`);

    if (body) {
        hmac.update(Buffer.from(JSON.stringify(body)));
    }

    return hmac.digest('hex');
}

/**
 * Rotates the token endpoint access key.
 *
 * @param environmentId
 * @param apiSecret
 * @returns
 */
async function rotateTokenEndpointAccessKey(environmentId, accessKeys) {
    const newAccessKey = {
        name: 'token endpoint access key',
        value: generateHex(36),
    };
    const response = await callApi(
        'POST',
        `/environments/${environmentId}/accesskeys`,
        newAccessKey
    );

    if (response.status !== 200) {
        const message = 'Unable create new access key.';
        console.log(message, response);
        throw new Error(message);
    }

    console.log('created new access key.', {
        environmentId,
    });

    // we want to only keep around the 2 newest secrets. We will delete all but the last 2.
    // we will sort by date ASC and delete the items in the list leaving around the last 2.
    const keysToDelete = accessKeys.sort(createdAtSort).splice(0, accessKeys.length - 2);

    for (const accessKey of keysToDelete) {
        // sanity check - make sure we aren't deleting the key we just created.
        if (accessKey.value === newAccessKey.value) {
            continue;
        }
        await callApi('DELETE', `/environments/${environmentId}/accesskeys/${accessKey.value}`);

        console.log('Deleted old access key.', {
            environmentId,
            accessKeyId: accessKey.value,
        });
    }

    return newAccessKey.value;
}

/**
 * Rotates the API secret.
 * The passed in secret will no longer be valid after this method.
 *
 * @param environmentId
 * @returns
 */
async function rotateApiSecret(environmentId) {
    // We have to first create the new secret, then we will update it to be the webhook secret.
    // Their system does not let you delete the webhook secret.
    const newSecret = await createApiSecret(environmentId);

    await removeOldSecrets(environmentId, newSecret.id);

    return newSecret.value;
}

/**
 * Create a new API Secret and set it to be the "webook" secret.
 *
 * @param environmentId
 * @returns
 */
async function createApiSecret(environmentId) {
    const newSecretPayload = {
        value: generateHex(120),
    };
    const response = await callApi(
        'POST',
        `/environments/${environmentId}/apisecrets`,
        newSecretPayload
    );

    if (response.status !== 200) {
        const message = 'Unable to create the new secret.';
        console.log(message, response);
        throw new Error(message);
    }

    console.log('Created new secret.', { environmentId });
    const { data: secrets } = await getApiSecrets(environmentId);

    const newSecret = secrets.find(
        (secret) =>
            newSecretPayload.value.slice(0, secret.trimmedValue.length) === secret.trimmedValue
    );

    if (!newSecret) {
        console.log({ secrets, newSecretPayload });
        throw new Error('Created secret not found');
    }

    // update the new secret to be the webhook secret.
    const updatedSecret = await callApi(
        'PATCH',
        `/environments/${environmentId}/apisecrets/${newSecret.id}`,
        { isWebhookApiSecret: true }
    );
    if (updatedSecret.error) {
        const message = 'Unable to update new secret to isWebhookApiSecret.';
        console.log(message, {
            error: updatedSecret.error,
            message: updatedSecret.errorData,
        });
        throw new Error(message);
    }
    console.log('updated new secret to be the webhook secret.', {
        environmentId,
        secretId: newSecret.id,
    });

    return {
        id: newSecret,
        value: newSecretPayload.value,
    };
}

/**
 * Remove all secrets except 2 most recent
 *
 * @param environmentId
 * @param newSecretId optional id of the new secret to not delete.
 */
async function removeOldSecrets(environmentId, newSecretId) {
    const { data: secrets } = await getApiSecrets(environmentId);

    // delete all but the 2 oldest secrets
    const secretsToDelete = secrets.sort(createdAtSort).splice(0, secrets.length - 2);

    for (const secret of secretsToDelete) {
        if (secret.id === newSecretId) {
            console.log('Not deleting new secret.', {
                environmentId,
                seceretId: secret.id,
            });
            continue;
        }
        const deleted = await callApi(
            'DELETE',
            `/environments/${environmentId}/apisecrets/${secret.id}`
        );

        if (deleted.error) {
            const message = 'Unable to delete a secret.';
            console.log(message, {
                error: deleted.error,
                message: deleted.errorData,
            });
            throw new Error(message);
        }
        console.log('Deleted old secrets.', { environmentId, seceretId: secret.id });
    }
}

/**
 * [Get Environments API Secrets](https://environments.cke-cs.com/docs#/Environments/get_environments__environmentId__apisecrets)
 * Gets all of an environments API secrets. This will ofuscate the actual secrets.
 *
 * @param tenantCuid
 * @returns
 */
async function getApiSecrets(environmentId) {
    return await callApi('GET', `/environments/${environmentId}/apisecrets`);
}

const extractTenantId = (name) => name.replace('Tenant ', '').replace(' Environment', '');

const getEnvironmentIdByTenantId = () => {
    const tenantEqualsEnvironmentIdArgs = process.argv.slice(2);

    if (tenantEqualsEnvironmentIdArgs.find((arg) => arg.split('=').length !== 2)) {
        throw new Error('arguments must each be TENANT_CUID=ENVIRONMENT_ID');
    }

    return tenantEqualsEnvironmentIdArgs.reduce((acc, arg) => {
        const [tenantId, environmentId] = arg.split('=');
        acc[tenantId] = environmentId;
        return acc;
    }, {});
};

const getValidatedEnvironments = async () => {
    const environmentIdByTenantId = getEnvironmentIdByTenantId();

    const { data: environments } = await callApi('GET', '/environments');

    const uniqueTenantCount = new Set(environments.map((environment) => environment.name)).size;
    const validatedEnvironments = [];

    for (const environment of environments) {
        const tenantId = extractTenantId(environment.name);

        // validate tenant has one environment
        if (
            !environmentIdByTenantId[tenantId] &&
            validatedEnvironments.some(
                (environment) => extractTenantId(environment.name) === tenantId
            )
        ) {
            const fs = require('node:fs');
            fs.writeFileSync('./environments.txt', JSON.stringify(environments), err => {
              if (err) {
                console.error(err);
              }
            });
            throw new Error(
                `More than 1 environment for ${tenantId}. Please specify argument TENANT_CUID=ENVIRONMENT_ID.`
            );
        }

        // continue if arg has tenant id and environment doesn't match arg
        if (
            environmentIdByTenantId[tenantId] &&
            environmentIdByTenantId[tenantId] !== environment.id
        ) {
            console.log('SKIP: ' + environment.id);
            continue;
        }

        validatedEnvironments.push(environment);
    }

    if (uniqueTenantCount !== validatedEnvironments.length) {
        throw new Error('Tenants do not each have a config.');
    }

    return validatedEnvironments;
};

async function recover() {
    const environments = await getValidatedEnvironments();

    const ckeditorServerConfig = {};

    for (const environment of environments) {
        const tenantId = extractTenantId(environment.name);

        // create secret
        const apiSecret = await rotateApiSecret(environment.id);

        // create endpoint access key
        const tokenEndpointAccessKey = await rotateTokenEndpointAccessKey(
            environment.id,
            environment.accessKeys
        );

        ckeditorServerConfig[tenantId] = {
            environment_id: environment.id,
            api_secret: apiSecret,
            token_endpoint_access_key: tokenEndpointAccessKey,
        };
    }

    console.log(Buffer.from(JSON.stringify(ckeditorServerConfig)).toString('base64'));
}

recover();