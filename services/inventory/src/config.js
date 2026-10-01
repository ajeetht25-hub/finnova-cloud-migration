'use strict';

const fs = require('node:fs');

/**
 * Load DB credentials. In Kubernetes the Secrets Store CSI driver mounts the
 * Secrets Manager secret as a file (DB_SECRET_FILE). Nothing is baked into the
 * image, nothing is passed as an env var, and nothing is read from a static
 * config file with plaintext credentials any more.
 *
 * Expected JSON: { "username": "...", "password": "...", "host": "...", "port": 3306 }
 */
function loadDbConfig(env = process.env, readFile = fs.readFileSync) {
  const file = env.DB_SECRET_FILE || '/mnt/secrets/db';
  let raw;
  try {
    raw = readFile(file, 'utf8');
  } catch (err) {
    const e = new Error(`DB secret not readable at ${file}`);
    e.code = 'SECRET_UNAVAILABLE';
    throw e;
  }
  const parsed = JSON.parse(raw);
  for (const k of ['username', 'password', 'host']) {
    if (!parsed[k]) {
      throw new Error(`DB secret is missing field "${k}"`);
    }
  }
  return { port: 3306, ...parsed, ssl: true }; // TLS required by RDS (require_secure_transport=1)
}

module.exports = { loadDbConfig };
