'use strict';

const test = require('node:test');
const assert = require('node:assert');
const { loadDbConfig } = require('../src/config');

test('loads credentials from the mounted secret file and forces TLS', () => {
  const secret = JSON.stringify({ username: 'inv', password: 'x', host: 'db.internal' });
  const cfg = loadDbConfig({ DB_SECRET_FILE: '/mnt/secrets/db' }, () => secret);
  assert.strictEqual(cfg.host, 'db.internal');
  assert.strictEqual(cfg.port, 3306);
  assert.strictEqual(cfg.ssl, true);
});

test('fails clearly when the secret is not mounted', () => {
  assert.throws(
    () => loadDbConfig({}, () => { throw new Error('ENOENT'); }),
    (err) => err.code === 'SECRET_UNAVAILABLE'
  );
});

test('rejects a secret with missing fields', () => {
  assert.throws(() => loadDbConfig({}, () => JSON.stringify({ username: 'a' })), /missing field/);
});
