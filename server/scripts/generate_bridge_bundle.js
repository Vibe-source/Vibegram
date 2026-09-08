#!/usr/bin/env node
/**
 * Bridge Bundle Generator & Signer
 *
 * Generates a signed BridgeBundle JSON that can be:
 * 1. Set as BLACKOUT_BRIDGE_BUNDLE_JSON env var on the server
 * 2. Baked into the native app's bridge configuration
 * 3. Distributed via QR code or text import
 *
 * Usage:
 *   # First time: generate a keypair
 *   node generate_bridge_bundle.js --generate-keys
 *
 *   # Then: create a signed bundle
 *   node generate_bridge_bundle.js \
 *     --private-key ./bridge_control.pem \
 *     --bridge "https://bridge1.example.com" \
 *     --bridge "https://bridge2.example.com" \
 *     --ttl 30d \
 *     --output bundle.json
 *
 *   # Or with full descriptor options:
 *   node generate_bridge_bundle.js \
 *     --private-key ./bridge_control.pem \
 *     --descriptor '{"id":"br1","host":"1.2.3.4","port":443,"spkiPins":["abc123"],"priority":0}' \
 *     --descriptor '{"id":"br2","baseUrl":"https://bridge2.example.com","priority":1}' \
 *     --ttl 7d
 */

const crypto = require('crypto');
const fs = require('fs');
const path = require('path');

function parseArgs(argv) {
  const args = {
    generateKeys: false,
    privateKeyPath: null,
    bridges: [],
    descriptors: [],
    ttl: '30d',
    output: null,
    publicKeyPath: null,
    verify: null,
  };

  for (let i = 2; i < argv.length; i++) {
    const arg = argv[i];
    switch (arg) {
      case '--generate-keys':
        args.generateKeys = true;
        break;
      case '--private-key':
        args.privateKeyPath = argv[++i];
        break;
      case '--public-key':
        args.publicKeyPath = argv[++i];
        break;
      case '--bridge':
        args.bridges.push(argv[++i]);
        break;
      case '--descriptor':
        args.descriptors.push(JSON.parse(argv[++i]));
        break;
      case '--ttl':
        args.ttl = argv[++i];
        break;
      case '--output':
      case '-o':
        args.output = argv[++i];
        break;
      case '--verify':
        args.verify = argv[++i];
        break;
      case '--help':
      case '-h':
        printUsage();
        process.exit(0);
      default:
        console.error(`Unknown argument: ${arg}`);
        process.exit(1);
    }
  }
  return args;
}

function printUsage() {
  console.log(`
Bridge Bundle Generator

Commands:
  --generate-keys                Generate Ed25519 keypair
  --verify <bundle.json>         Verify a bundle's signature

Bundle creation:
  --private-key <path>           Path to Ed25519 private key PEM
  --bridge <url>                 Add a bridge by URL (can repeat)
  --descriptor <json>            Add a bridge descriptor JSON (can repeat)
  --ttl <duration>               Bundle TTL (e.g. 7d, 30d, 1h) [default: 30d]
  --output <path>                Output file path [default: stdout]
  --public-key <path>            Public key path (for --generate-keys output)
  `);
}

function parseTTL(ttl) {
  const match = ttl.match(/^(\d+)(s|m|h|d)$/);
  if (!match) throw new Error(`Invalid TTL format: ${ttl}. Use e.g. 7d, 24h, 30m`);
  const value = parseInt(match[1], 10);
  const unit = match[2];
  const multipliers = { s: 1000, m: 60_000, h: 3_600_000, d: 86_400_000 };
  return value * multipliers[unit];
}

function generateKeys(args) {
  const { publicKey, privateKey } = crypto.generateKeyPairSync('ed25519', {
    publicKeyEncoding: { type: 'spki', format: 'pem' },
    privateKeyEncoding: { type: 'pkcs8', format: 'pem' },
  });

  const privPath = args.privateKeyPath || 'bridge_control.pem';
  const pubPath = args.publicKeyPath || privPath.replace('.pem', '_pub.pem');

  fs.writeFileSync(privPath, privateKey, { mode: 0o600 });
  fs.writeFileSync(pubPath, publicKey);

  console.log(`✅ Generated Ed25519 keypair:`);
  console.log(`   Private key: ${privPath}`);
  console.log(`   Public key:  ${pubPath}`);
  console.log('');
  console.log('Add the public key to your app config:');
  console.log('   Native bridge control keys:');
  console.log(`   ${JSON.stringify([publicKey.trim()])}`);
  console.log('');
  console.log('⚠️  Keep the private key safe! It signs bridge bundles.');
}

function stableSortKeys(value) {
  if (Array.isArray(value)) return value.map(stableSortKeys);
  if (!value || typeof value !== 'object') return value;
  return Object.keys(value)
    .sort()
    .reduce((acc, key) => {
      acc[key] = stableSortKeys(value[key]);
      return acc;
    }, {});
}

function canonicalize(bundle) {
  const payload = {
    version: bundle.version,
    generatedAt: bundle.generatedAt,
    expiresAt: bundle.expiresAt,
    descriptors: bundle.descriptors.map((d) => ({
      id: d.id,
      host: d.host,
      port: d.port,
      pathPrefix: d.pathPrefix,
      transport: d.transport,
      spkiPins: d.spkiPins || [],
      priority: d.priority,
      weight: d.weight,
      expiresAt: d.expiresAt,
      origin: d.origin,
      baseUrl: d.baseUrl,
    })),
  };
  return JSON.stringify(stableSortKeys(payload));
}

function createBundle(args) {
  if (!args.privateKeyPath) {
    console.error('Error: --private-key is required');
    process.exit(1);
  }

  const privateKeyPem = fs.readFileSync(args.privateKeyPath, 'utf8');
  const privateKey = crypto.createPrivateKey(privateKeyPem);

  // Build descriptors from --bridge URLs and/or --descriptor JSON
  const descriptors = [];
  let priority = 0;

  for (const url of args.bridges) {
    const parsed = new URL(url);
    descriptors.push({
      id: parsed.hostname,
      host: parsed.hostname,
      port: parsed.port ? parseInt(parsed.port, 10) : 443,
      pathPrefix: parsed.pathname === '/' ? undefined : parsed.pathname,
      transport: parsed.protocol === 'http:' ? 'http' : 'https',
      spkiPins: [],
      priority: priority++,
      weight: 100,
      origin: 'official',
      baseUrl: url.replace(/\/$/, ''),
    });
  }

  for (const desc of args.descriptors) {
    descriptors.push({
      id: desc.id || desc.host || `bridge-${priority}`,
      host: desc.host,
      port: desc.port || 443,
      pathPrefix: desc.pathPrefix,
      transport: desc.transport || 'https',
      spkiPins: desc.spkiPins || [],
      priority: desc.priority ?? priority++,
      weight: desc.weight ?? 100,
      expiresAt: desc.expiresAt,
      origin: desc.origin || 'official',
      baseUrl: desc.baseUrl,
    });
  }

  if (descriptors.length === 0) {
    console.error('Error: At least one --bridge or --descriptor is required');
    process.exit(1);
  }

  const now = Date.now();
  const ttlMs = parseTTL(args.ttl);

  const bundle = {
    version: 1,
    generatedAt: now,
    expiresAt: now + ttlMs,
    descriptors,
  };

  // Sign
  const canonical = canonicalize(bundle);
  const signature = crypto.sign(null, Buffer.from(canonical, 'utf8'), privateKey);
  bundle.signature = signature.toString('base64');

  const json = JSON.stringify(bundle, null, 2);

  if (args.output) {
    fs.writeFileSync(args.output, json);
    console.log(`✅ Bundle written to ${args.output}`);
    console.log(`   ${descriptors.length} bridge(s), expires in ${args.ttl}`);
    console.log('');
    console.log('Set as env var:');
    console.log(`   BLACKOUT_BRIDGE_BUNDLE_JSON='${JSON.stringify(bundle)}'`);
  } else {
    console.log(json);
  }
}

function verifyBundle(bundlePath, args) {
  const pubKeyPath = args.publicKeyPath;
  if (!pubKeyPath) {
    console.error('Error: --public-key is required for verification');
    process.exit(1);
  }

  const bundleJson = fs.readFileSync(bundlePath, 'utf8');
  const bundle = JSON.parse(bundleJson);
  const publicKeyPem = fs.readFileSync(pubKeyPath, 'utf8');
  const publicKey = crypto.createPublicKey(publicKeyPem);

  const canonical = canonicalize(bundle);
  const signature = Buffer.from(bundle.signature, 'base64');
  const valid = crypto.verify(null, Buffer.from(canonical, 'utf8'), publicKey, signature);

  if (valid) {
    const expiresIn = bundle.expiresAt - Date.now();
    const expiresHours = Math.floor(expiresIn / 3_600_000);
    console.log(`✅ Signature valid`);
    console.log(`   ${bundle.descriptors.length} bridge(s)`);
    console.log(`   Generated: ${new Date(bundle.generatedAt).toISOString()}`);
    console.log(`   Expires:   ${new Date(bundle.expiresAt).toISOString()} (${expiresHours}h)`);
    if (expiresIn <= 0) console.log('   ⚠️  Bundle is EXPIRED');
  } else {
    console.error('❌ Signature INVALID');
    process.exit(1);
  }
}

// ── Main ─────────────────────────────────────────────────────────────

const args = parseArgs(process.argv);

if (args.generateKeys) {
  generateKeys(args);
} else if (args.verify) {
  verifyBundle(args.verify, args);
} else if (args.bridges.length > 0 || args.descriptors.length > 0) {
  createBundle(args);
} else {
  printUsage();
}
