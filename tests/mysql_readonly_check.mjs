#!/usr/bin/env node

// Read-only local MySQL connectivity and schema gate. Credentials must come
// from the process environment; never put MYSQL_PWD in command arguments.
import { spawnSync } from 'node:child_process';

const env = process.env;
const host = env.MYSQL_HOST || '127.0.0.1';
const port = env.MYSQL_PORT || '3306';
const user = env.MYSQL_USER;
const database = env.MYSQL_DATABASE;
const password = env.MYSQL_PASSWORD;
const mysql = env.MYSQL_CLIENT || 'mysql';
const expectedColumns = new Set([
  'account_id', 'account_name', 'password_salt', 'password_hash', 'created_at'
]);

const result = {
  driver: 'not checked',
  connection: 'blocked',
  schema: 'blocked',
  blockers: []
};

const lookup = spawnSync(mysql, ['--version'], { encoding: 'utf8', windowsHide: true });
if (lookup.error || lookup.status !== 0) {
  result.driver = 'not found';
  result.blockers.push('mysql client is not available');
} else {
  result.driver = 'found';
}

for (const [name, value] of [['MYSQL_USER', user], ['MYSQL_DATABASE', database], ['MYSQL_PASSWORD', password]]) {
  if (!value) result.blockers.push(`${name} is not provided by the process environment`);
}

function query(sql) {
  // MYSQL_PWD is inherited only by this child and is never placed in argv.
  const childEnv = { ...env };
  if (password) childEnv.MYSQL_PWD = password;
  const child = spawnSync(mysql, [
    '--protocol=tcp', '--connect-timeout=5', '-h', host, '-P', port, '-u', user || '',
    '--batch', '--raw', '--skip-column-names', database || '', '-e', sql
  ], { encoding: 'utf8', env: childEnv, windowsHide: true });
  if (child.error || child.status !== 0) return null;
  return child.stdout.trim();
}

if (result.driver === 'found' && user && database && password) {
  const version = query('SELECT VERSION();');
  if (version === null) {
    result.connection = 'failed';
    result.schema = 'not checked';
    result.blockers.push('MySQL connection/authentication failed');
  } else {
    result.connection = 'passed';
    const rows = query("SELECT column_name FROM information_schema.columns WHERE table_schema = DATABASE() AND table_name = 'accounts' ORDER BY ordinal_position;");
    const columns = rows ? rows.split(/\r?\n/).filter(Boolean) : [];
    const actual = new Set(columns);
    const missing = [...expectedColumns].filter((column) => !actual.has(column));
    if (rows !== null && missing.length === 0) {
      result.schema = 'passed';
    } else {
      result.schema = 'failed';
      result.blockers.push(rows === null ? 'schema metadata query failed' : `accounts schema missing: ${missing.join(', ')}`);
    }
  }
}

console.log(`MYSQL_DRIVER=${result.driver}`);
console.log(`MYSQL_CONNECTION=${result.connection}`);
console.log(`MYSQL_SCHEMA=${result.schema}`);
if (result.blockers.length) {
  console.log('MYSQL_BLOCKERS:');
  for (const blocker of result.blockers) console.log(`- ${blocker}`);
}

process.exitCode = result.connection === 'passed' && result.schema === 'passed' ? 0 : 1;
