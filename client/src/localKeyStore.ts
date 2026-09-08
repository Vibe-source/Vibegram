/**
 * Local Key Store - Secure storage for encryption keys
 *
 * IMPORTANT: Private keys MUST be stored locally for end-to-end encryption.
 * They should NEVER be sent to any server (including Supabase).
 *
 * KEY PERSISTENCE STRATEGY:
 * - Logout: Keeps keys in backup store (user can re-login on same device)
 * - Delete Account: Removes everything including backup
 * - New Device: Requires key import (QR code or recovery phrase)
 */

const DB_NAME = 'VibeKeyStore';
const DB_VERSION = 2;
const SESSION_STORE = 'sessions';
const BACKUP_STORE = 'keyBackup';

// localStorage fallback keys (more reliable than IndexedDB on mobile)
const LS_SESSION_KEY = 'vibe_session_backup';
const LS_KEYS_PREFIX = 'vibe_keys_';

interface StoredSession {
    id: string; // 'current'
    userId: string;
    username: string;
    secureId: string;
    loginToken: string;
    privateKeyJwk?: JsonWebKey;
    publicKeyJwk?: JsonWebKey;
    signPrivateKeyJwk?: JsonWebKey;
    signPublicKeyJwk?: JsonWebKey;
    advancedIdentityKeyJwk?: { privateKey: JsonWebKey; publicKey: JsonWebKey };
    advancedSigningKeyJwk?: { privateKey: JsonWebKey; publicKey: JsonWebKey };
    signedPreKeyJwk?: { privateKey: JsonWebKey; publicKey: JsonWebKey };
    supportsAdvanced?: boolean;
    secretKey?: string; // Stored for display
}

// Persisted keys that survive logout (stored separately)
interface PersistedKeys {
    id: string; // matches secureId
    userId: string;
    privateKeyJwk: JsonWebKey;
    publicKeyJwk: JsonWebKey;
    signPrivateKeyJwk?: JsonWebKey;
    signPublicKeyJwk?: JsonWebKey;
    secretKey?: string;
    createdAt: number;
}

// Recovery phrase export format
export interface KeyBackupData {
    version: number;
    userId: string;
    secureId: string;
    privateKeyJwk: JsonWebKey;
    publicKeyJwk: JsonWebKey;
    signPrivateKeyJwk?: JsonWebKey;
    signPublicKeyJwk?: JsonWebKey;
    secretKey?: string;
    exportedAt: number;
}

class LocalKeyStore {
    private db: IDBDatabase | null = null;

    // ========== localStorage FALLBACK (more reliable on mobile) ==========

    private saveToLocalStorage(session: StoredSession): void {
        try {
            // Save current session
            localStorage.setItem(LS_SESSION_KEY, JSON.stringify({
                id: session.id || 'current',
                userId: session.userId,
                username: session.username,
                secureId: session.secureId,
                loginToken: session.loginToken,
                privateKeyJwk: session.privateKeyJwk,
                publicKeyJwk: session.publicKeyJwk,
                signPrivateKeyJwk: session.signPrivateKeyJwk,
                signPublicKeyJwk: session.signPublicKeyJwk,
                advancedIdentityKeyJwk: session.advancedIdentityKeyJwk,
                advancedSigningKeyJwk: session.advancedSigningKeyJwk,
                signedPreKeyJwk: session.signedPreKeyJwk,
                supportsAdvanced: session.supportsAdvanced,
                secretKey: session.secretKey
            }));

            // Also save keys by secureId for backup
            if (session.secureId && session.privateKeyJwk) {
                localStorage.setItem(`${LS_KEYS_PREFIX}${session.secureId}`, JSON.stringify({
                    privateKeyJwk: session.privateKeyJwk,
                    publicKeyJwk: session.publicKeyJwk,
                    signPrivateKeyJwk: session.signPrivateKeyJwk,
                    signPublicKeyJwk: session.signPublicKeyJwk,
                    secretKey: session.secretKey,
                    createdAt: Date.now()
                }));
            }
            console.log('[KeyStore] Saved to localStorage backup');
        } catch (e) {
            console.warn('[KeyStore] localStorage backup failed:', e);
        }
    }

    private loadFromLocalStorage(): StoredSession | null {
        try {
            const data = localStorage.getItem(LS_SESSION_KEY);
            if (data) {
                const session = JSON.parse(data);
                console.log('[KeyStore] Loaded from localStorage backup');
                return session;
            }
        } catch (e) {
            console.warn('[KeyStore] localStorage load failed:', e);
        }
        return null;
    }

    private getBackupFromLocalStorage(secureId: string): PersistedKeys | null {
        try {
            const data = localStorage.getItem(`${LS_KEYS_PREFIX}${secureId}`);
            if (data) {
                const keys = JSON.parse(data);
                console.log('[KeyStore] Loaded backup keys from localStorage');
                return {
                    id: secureId,
                    userId: secureId,
                    ...keys
                };
            }
        } catch (e) {
            console.warn('[KeyStore] localStorage backup keys load failed:', e);
        }
        return null;
    }

    private clearLocalStorage(): void {
        try {
            localStorage.removeItem(LS_SESSION_KEY);
            // Don't clear key backups - they survive logout
        } catch (e) {
            console.warn('[KeyStore] localStorage clear failed:', e);
        }
    }

    private clearAllLocalStorage(): void {
        try {
            localStorage.removeItem(LS_SESSION_KEY);
            // Clear all key backups (vibe_keys_* and securechat_backup_*)
            const keysToRemove: string[] = [];
            for (let i = 0; i < localStorage.length; i++) {
                const key = localStorage.key(i);
                if (
                    key?.startsWith(LS_KEYS_PREFIX) ||
                    key?.startsWith('securechat_backup_')
                ) {
                    keysToRemove.push(key);
                }
            }
            keysToRemove.forEach(k => localStorage.removeItem(k));
        } catch (e) {
            console.warn('[KeyStore] localStorage clearAll failed:', e);
        }
    }

    private async openDB(): Promise<IDBDatabase> {
        if (this.db) return this.db;

        return new Promise((resolve, reject) => {
            const request = indexedDB.open(DB_NAME, DB_VERSION);

            request.onerror = () => {
                console.error('[KeyStore] Failed to open database:', request.error);
                reject(request.error);
            };

            request.onsuccess = () => {
                this.db = request.result;
                resolve(request.result);
            };

            request.onupgradeneeded = (event) => {
                const db = (event.target as IDBOpenDBRequest).result;
                // Session store (cleared on logout)
                if (!db.objectStoreNames.contains(SESSION_STORE)) {
                    db.createObjectStore(SESSION_STORE, { keyPath: 'id' });
                }
                // Backup store (persists across logout)
                if (!db.objectStoreNames.contains(BACKUP_STORE)) {
                    db.createObjectStore(BACKUP_STORE, { keyPath: 'id' });
                }
                // Migration from old 'keys' store
                if (db.objectStoreNames.contains('keys')) {
                    // Will be handled after upgrade
                }
            };
        });
    }

    // Migrate from old schema if needed
    private async migrateIfNeeded(): Promise<void> {
        const db = await this.openDB();
        if (db.objectStoreNames.contains('keys')) {
            try {
                const tx = db.transaction('keys', 'readonly');
                const store = tx.objectStore('keys');
                const request = store.get('current');
                request.onsuccess = async () => {
                    if (request.result) {
                        // Migrate to new session store
                        await this.saveSession(request.result);
                        // Also backup the keys
                        if (request.result.privateKeyJwk) {
                            await this.backupKeys(request.result);
                        }
                    }
                };
            } catch (e) {
                console.warn('[KeyStore] Migration check failed:', e);
            }
        }
    }

    async saveSession(session: Omit<StoredSession, 'id'>): Promise<void> {
        const sessionWithId = { id: 'current', ...session } as StoredSession;

        // ALWAYS save to localStorage first (most reliable on mobile)
        this.saveToLocalStorage(sessionWithId);

        // Then try IndexedDB
        try {
            const db = await this.openDB();
            return new Promise((resolve,) => {
                const tx = db.transaction(SESSION_STORE, 'readwrite');
                const store = tx.objectStore(SESSION_STORE);
                store.put(sessionWithId);
                tx.oncomplete = () => {
                    // Also backup keys for persistence
                    if (session.privateKeyJwk && session.publicKeyJwk) {
                        this.backupKeys(sessionWithId).catch(console.error);
                    }
                    resolve();
                };
                tx.onerror = () => {
                    console.warn('[KeyStore] IndexedDB save failed, but localStorage backup exists');
                    resolve(); // Don't reject - localStorage has the backup
                };
            });
        } catch (e) {
            console.warn('[KeyStore] IndexedDB unavailable, using localStorage only:', e);
            // localStorage already saved above, so we're ok
        }
    }

    async loadSession(): Promise<StoredSession | null> {
        // Try IndexedDB first
        try {
            await this.migrateIfNeeded();
            const db = await this.openDB();
            const idbSession = await new Promise<StoredSession | null>((resolve, reject) => {
                const tx = db.transaction(SESSION_STORE, 'readonly');
                const store = tx.objectStore(SESSION_STORE);
                const request = store.get('current');
                request.onsuccess = () => resolve(request.result || null);
                request.onerror = () => reject(request.error);
            });

            if (idbSession?.privateKeyJwk) {
                console.log('[KeyStore] Loaded session from IndexedDB');
                // Ensure localStorage is synced
                this.saveToLocalStorage(idbSession);
                return idbSession;
            }
        } catch (e) {
            console.warn('[KeyStore] IndexedDB load failed:', e);
        }

        // Fallback to localStorage
        const lsSession = this.loadFromLocalStorage();
        if (lsSession?.privateKeyJwk) {
            console.log('[KeyStore] Recovered session from localStorage fallback');
            return lsSession;
        }

        console.warn('[KeyStore] No session found in IndexedDB or localStorage');
        return null;
    }

    // Clear session but KEEP keys in backup (for re-login)
    async clearSession(): Promise<void> {
        // Clear localStorage session (but keep key backups)
        this.clearLocalStorage();

        try {
            const db = await this.openDB();
            return new Promise((resolve) => {
                const tx = db.transaction(SESSION_STORE, 'readwrite');
                const store = tx.objectStore(SESSION_STORE);
                store.delete('current');
                tx.oncomplete = () => resolve();
                tx.onerror = () => {
                    console.warn('[KeyStore] IndexedDB clear failed, but localStorage cleared');
                    resolve();
                };
            });
        } catch (e) {
            console.error('[KeyStore] Failed to clear session:', e);
        }
    }

    // Full wipe - used for delete account
    async clearAll(): Promise<void> {
        // Clear all localStorage data
        this.clearAllLocalStorage();

        try {
            const db = await this.openDB();
            return new Promise((resolve) => {
                const tx = db.transaction([SESSION_STORE, BACKUP_STORE], 'readwrite');
                tx.objectStore(SESSION_STORE).clear();
                tx.objectStore(BACKUP_STORE).clear();
                tx.oncomplete = () => resolve();
                tx.onerror = () => {
                    console.warn('[KeyStore] IndexedDB clearAll failed, but localStorage cleared');
                    resolve();
                };
            });
        } catch (e) {
            console.error('[KeyStore] Failed to clear all:', e);
        }
    }

    // Backup keys separately (survives logout)
    private async backupKeys(session: StoredSession): Promise<void> {
        if (!session.privateKeyJwk || !session.publicKeyJwk || !session.secureId) return;

        const db = await this.openDB();
        return new Promise((resolve, reject) => {
            const tx = db.transaction(BACKUP_STORE, 'readwrite');
            const store = tx.objectStore(BACKUP_STORE);
            const backup: PersistedKeys = {
                id: session.secureId,
                userId: session.userId,
                privateKeyJwk: session.privateKeyJwk!,
                publicKeyJwk: session.publicKeyJwk!,
                signPrivateKeyJwk: session.signPrivateKeyJwk,
                signPublicKeyJwk: session.signPublicKeyJwk,
                secretKey: session.secretKey,
                createdAt: Date.now()
            };
            store.put(backup);
            tx.oncomplete = () => resolve();
            tx.onerror = () => reject(tx.error);
        });
    }

    // PUBLIC: Save backup keys for a user (for explicit backup from Auth)
    async saveBackupKeys(userId: string, secureId: string, keys: { privateKeyJwk: JsonWebKey, publicKeyJwk: JsonWebKey }): Promise<void> {
        const db = await this.openDB();

        // Save to IndexedDB
        await new Promise<void>((resolve, reject) => {
            const tx = db.transaction(BACKUP_STORE, 'readwrite');
            const store = tx.objectStore(BACKUP_STORE);
            const backup: PersistedKeys = {
                id: secureId,  // Use secureId as the key
                userId: userId,
                privateKeyJwk: keys.privateKeyJwk,
                publicKeyJwk: keys.publicKeyJwk,
                createdAt: Date.now()
            };
            store.put(backup);

            // Also store by userId for easier lookup
            const userBackup: PersistedKeys = {
                id: userId,
                userId: userId,
                privateKeyJwk: keys.privateKeyJwk,
                publicKeyJwk: keys.publicKeyJwk,
                createdAt: Date.now()
            };
            store.put(userBackup);

            tx.oncomplete = () => resolve();
            tx.onerror = () => reject(tx.error);
        });

        // Also save to localStorage as backup
        try {
            localStorage.setItem(`securechat_backup_${secureId}`, JSON.stringify({
                privateKeyJwk: keys.privateKeyJwk,
                publicKeyJwk: keys.publicKeyJwk
            }));
            localStorage.setItem(`securechat_backup_${userId}`, JSON.stringify({
                privateKeyJwk: keys.privateKeyJwk,
                publicKeyJwk: keys.publicKeyJwk
            }));
            console.log('[KeyStore] Saved backup to localStorage for', userId, 'and', secureId);
        } catch (e) {
            console.warn('[KeyStore] localStorage backup failed:', e);
        }
    }

    // Get backed up keys for a secureId (after logout, re-login)
    async getBackupKeys(secureId: string): Promise<PersistedKeys | null> {
        // Try IndexedDB first
        try {
            const db = await this.openDB();
            const idbBackup = await new Promise<PersistedKeys | null>((resolve, reject) => {
                const tx = db.transaction(BACKUP_STORE, 'readonly');
                const store = tx.objectStore(BACKUP_STORE);
                const request = store.get(secureId);
                request.onsuccess = () => resolve(request.result || null);
                request.onerror = () => reject(request.error);
            });

            if (idbBackup?.privateKeyJwk) {
                console.log('[KeyStore] Found backup keys in IndexedDB');
                return idbBackup;
            }
        } catch (e) {
            console.warn('[KeyStore] IndexedDB backup retrieval failed:', e);
        }

        // Fallback to localStorage
        const lsBackup = this.getBackupFromLocalStorage(secureId);
        if (lsBackup?.privateKeyJwk) {
            console.log('[KeyStore] Recovered backup keys from localStorage');
            return lsBackup;
        }

        console.warn('[KeyStore] No backup keys found for:', secureId);
        return null;
    }

    // Get all backed up keys (for account selection)
    async getAllBackups(): Promise<PersistedKeys[]> {
        try {
            const db = await this.openDB();
            return new Promise((resolve, reject) => {
                const tx = db.transaction(BACKUP_STORE, 'readonly');
                const store = tx.objectStore(BACKUP_STORE);
                const request = store.getAll();
                request.onsuccess = () => resolve(request.result || []);
                request.onerror = () => reject(request.error);
            });
        } catch (e) {
            console.error('[KeyStore] Failed to get all backups:', e);
            return [];
        }
    }

    async hasSession(): Promise<boolean> {
        const session = await this.loadSession();
        return !!session?.userId;
    }

    // Import the stored RSA key pair
    async importStoredKeyPair(session: StoredSession): Promise<CryptoKeyPair | null> {
        if (!session.privateKeyJwk || !session.publicKeyJwk) return null;

        try {
            const privateKey = await crypto.subtle.importKey(
                'jwk',
                session.privateKeyJwk,
                { name: 'RSA-OAEP', hash: 'SHA-256' },
                true,
                ['decrypt']
            );
            const publicKey = await crypto.subtle.importKey(
                'jwk',
                session.publicKeyJwk,
                { name: 'RSA-OAEP', hash: 'SHA-256' },
                true,
                ['encrypt']
            );
            return { privateKey, publicKey };
        } catch (e) {
            console.error('[KeyStore] Failed to import key pair:', e);
            return null;
        }
    }

    // ========== KEY EXPORT/IMPORT FOR MULTI-DEVICE ==========

    // Export keys as JSON (can be encrypted with password)
    async exportKeys(password?: string): Promise<string | null> {
        const session = await this.loadSession();
        if (!session?.privateKeyJwk || !session?.publicKeyJwk) {
            console.error('[KeyStore] No keys to export');
            return null;
        }

        const exportData: KeyBackupData = {
            version: 1,
            userId: session.userId,
            secureId: session.secureId,
            privateKeyJwk: session.privateKeyJwk,
            publicKeyJwk: session.publicKeyJwk,
            signPrivateKeyJwk: session.signPrivateKeyJwk,
            signPublicKeyJwk: session.signPublicKeyJwk,
            exportedAt: Date.now()
        };

        const json = JSON.stringify(exportData);

        if (password) {
            // Encrypt with password using PBKDF2 + AES-GCM
            return await this.encryptWithPassword(json, password);
        }

        // Return base64 encoded (not encrypted - for QR code)
        return btoa(json);
    }

    // Import keys from backup string
    async importKeys(backupString: string, password?: string): Promise<KeyBackupData | null> {
        try {
            let json: string;

            if (password) {
                // Decrypt with password
                const decrypted = await this.decryptWithPassword(backupString, password);
                if (!decrypted) return null;
                json = decrypted;
            } else {
                // Assume base64 encoded
                json = atob(backupString);
            }

            const data: KeyBackupData = JSON.parse(json);

            // Validate structure
            if (!data.version || !data.privateKeyJwk || !data.publicKeyJwk) {
                throw new Error('Invalid backup format');
            }

            return data;
        } catch (e) {
            console.error('[KeyStore] Failed to import keys:', e);
            return null;
        }
    }

    // Generate a recovery phrase (12 words) from keys
    async generateRecoveryPhrase(): Promise<string | null> {
        const session = await this.loadSession();
        if (!session?.privateKeyJwk) return null;

        // Create a deterministic hash from the private key
        const keyData = JSON.stringify(session.privateKeyJwk);
        const encoder = new TextEncoder();
        const data = encoder.encode(keyData);
        const hashBuffer = await crypto.subtle.digest('SHA-256', data);
        const hashArray = new Uint8Array(hashBuffer);

        // Convert to word indices (BIP39-like, simplified)
        const words = WORD_LIST;
        const phraseWords: string[] = [];

        for (let i = 0; i < 12; i++) {
            const index = (hashArray[i * 2] << 8 | hashArray[i * 2 + 1]) % words.length;
            phraseWords.push(words[index]);
        }

        return phraseWords.join(' ');
    }

    // Password-based encryption helpers
    private async encryptWithPassword(plaintext: string, password: string): Promise<string> {
        const encoder = new TextEncoder();
        const salt = crypto.getRandomValues(new Uint8Array(16));
        const iv = crypto.getRandomValues(new Uint8Array(12));

        // Derive key from password
        const keyMaterial = await crypto.subtle.importKey(
            'raw',
            encoder.encode(password),
            'PBKDF2',
            false,
            ['deriveBits', 'deriveKey']
        );

        const key = await crypto.subtle.deriveKey(
            { name: 'PBKDF2', salt, iterations: 600000, hash: 'SHA-256' },  // SECURITY: OWASP 2023
            keyMaterial,
            { name: 'AES-GCM', length: 256 },
            false,
            ['encrypt']
        );

        const encrypted = await crypto.subtle.encrypt(
            { name: 'AES-GCM', iv },
            key,
            encoder.encode(plaintext)
        );

        // Combine salt + iv + encrypted
        const combined = new Uint8Array(salt.length + iv.length + encrypted.byteLength);
        combined.set(salt, 0);
        combined.set(iv, salt.length);
        combined.set(new Uint8Array(encrypted), salt.length + iv.length);

        return btoa(String.fromCharCode(...combined));
    }

    private async decryptWithPassword(ciphertext: string, password: string): Promise<string | null> {
        try {
            const encoder = new TextEncoder();
            const decoder = new TextDecoder();

            const combined = Uint8Array.from(atob(ciphertext), c => c.charCodeAt(0));
            const salt = combined.slice(0, 16);
            const iv = combined.slice(16, 28);
            const encrypted = combined.slice(28);

            const keyMaterial = await crypto.subtle.importKey(
                'raw',
                encoder.encode(password),
                'PBKDF2',
                false,
                ['deriveBits', 'deriveKey']
            );

            const key = await crypto.subtle.deriveKey(
                { name: 'PBKDF2', salt, iterations: 600000, hash: 'SHA-256' },  // SECURITY: OWASP 2023
                keyMaterial,
                { name: 'AES-GCM', length: 256 },
                false,
                ['decrypt']
            );

            const decrypted = await crypto.subtle.decrypt(
                { name: 'AES-GCM', iv },
                key,
                encrypted
            );

            return decoder.decode(decrypted);
        } catch (e) {
            console.error('[KeyStore] Decryption failed (wrong password?):', e);
            return null;
        }
    }
}

// Simplified BIP39 word list (first 256 words for demo)
const WORD_LIST = [
    'abandon', 'ability', 'able', 'about', 'above', 'absent', 'absorb', 'abstract',
    'absurd', 'abuse', 'access', 'accident', 'account', 'accuse', 'achieve', 'acid',
    'acoustic', 'acquire', 'across', 'act', 'action', 'actor', 'actress', 'actual',
    'adapt', 'add', 'addict', 'address', 'adjust', 'admit', 'adult', 'advance',
    'advice', 'aerobic', 'affair', 'afford', 'afraid', 'again', 'age', 'agent',
    'agree', 'ahead', 'aim', 'air', 'airport', 'aisle', 'alarm', 'album',
    'alcohol', 'alert', 'alien', 'all', 'alley', 'allow', 'almost', 'alone',
    'alpha', 'already', 'also', 'alter', 'always', 'amateur', 'amazing', 'among',
    'amount', 'amused', 'analyst', 'anchor', 'ancient', 'anger', 'angle', 'angry',
    'animal', 'ankle', 'announce', 'annual', 'another', 'answer', 'antenna', 'antique',
    'anxiety', 'any', 'apart', 'apology', 'appear', 'apple', 'approve', 'april',
    'arch', 'arctic', 'area', 'arena', 'argue', 'arm', 'armed', 'armor',
    'army', 'around', 'arrange', 'arrest', 'arrive', 'arrow', 'art', 'artefact',
    'artist', 'artwork', 'ask', 'aspect', 'assault', 'asset', 'assist', 'assume',
    'asthma', 'athlete', 'atom', 'attack', 'attend', 'attitude', 'attract', 'auction',
    'audit', 'august', 'aunt', 'author', 'auto', 'autumn', 'average', 'avocado',
    'avoid', 'awake', 'aware', 'away', 'awesome', 'awful', 'awkward', 'axis',
    'baby', 'bachelor', 'bacon', 'badge', 'bag', 'balance', 'balcony', 'ball',
    'bamboo', 'banana', 'banner', 'bar', 'barely', 'bargain', 'barrel', 'base',
    'basic', 'basket', 'battle', 'beach', 'bean', 'beauty', 'because', 'become',
    'beef', 'before', 'begin', 'behave', 'behind', 'believe', 'below', 'belt',
    'bench', 'benefit', 'best', 'betray', 'better', 'between', 'beyond', 'bicycle',
    'bid', 'bike', 'bind', 'biology', 'bird', 'birth', 'bitter', 'black',
    'blade', 'blame', 'blanket', 'blast', 'bleak', 'bless', 'blind', 'blood',
    'blossom', 'blouse', 'blue', 'blur', 'blush', 'board', 'boat', 'body',
    'boil', 'bomb', 'bone', 'bonus', 'book', 'boost', 'border', 'boring',
    'borrow', 'boss', 'bottom', 'bounce', 'box', 'boy', 'bracket', 'brain',
    'brand', 'brass', 'brave', 'bread', 'breeze', 'brick', 'bridge', 'brief',
    'bright', 'bring', 'brisk', 'broccoli', 'broken', 'bronze', 'broom', 'brother',
    'brown', 'brush', 'bubble', 'buddy', 'budget', 'buffalo', 'build', 'bulb',
    'bulk', 'bullet', 'bundle', 'bunker', 'burden', 'burger', 'burst', 'bus',
    'business', 'busy', 'butter', 'buyer', 'buzz', 'cabbage', 'cabin', 'cable'
];

// Singleton instance
export const keyStore = new LocalKeyStore();
export default keyStore;
