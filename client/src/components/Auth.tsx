import React, { useState } from 'react';
import { motion, AnimatePresence, useReducedMotion } from 'framer-motion';
import { Copy, Check, Eye, EyeOff, Shield } from 'lucide-react';
import { ContourField } from './vfx/ContourField';
import {
    deriveKeyFromPassphrase, decryptPrivateKey, importPublicKey
} from '../crypto';
import { getApiUrl } from '../utils';
import { keyStore } from '../localKeyStore';
import './Auth.css';

const saveSession = (session: any) => keyStore.saveSession(session);

interface AuthProps {
    onSuccess: (data: { userId: string, username: string, secureId: string, loginToken: string, keys: CryptoKeyPair }) => void;
    setView: (view: any) => void;
}

type AuthStep = 'form' | 'reveal';

const Auth: React.FC<AuthProps> = ({ onSuccess }) => {
    const [username, setUsername] = useState('');
    const [secretKey, setSecretKey] = useState('');
    const [error, setError] = useState('');
    const [isLoading, setIsLoading] = useState(false);
    const [formType, setFormType] = useState<'login' | 'register'>('register');
    const [step, setStep] = useState<AuthStep>('form');
    const [revealedSecret, setRevealedSecret] = useState('');
    const [secretVisible, setSecretVisible] = useState(false);
    const [copied, setCopied] = useState(false);
    const [ackSaved, setAckSaved] = useState(false);
    const [pendingSuccess, setPendingSuccess] = useState<{
        userId: string;
        username: string;
        secureId: string;
        loginToken: string;
        keys: CryptoKeyPair;
    } | null>(null);

    const prefersReducedMotion = useReducedMotion();
    const panelTransition = prefersReducedMotion
        ? { duration: 0 }
        : { duration: 0.22, ease: [0.22, 1, 0.36, 1] as const };
    const panelInitial = prefersReducedMotion ? false : { opacity: 0, y: 10 };
    const panelAnimate = { opacity: 1, y: 0 };
    const panelExit = prefersReducedMotion ? { opacity: 0 } : { opacity: 0, y: -8 };

    const generateSecretKey = () => {
        const array = new Uint8Array(32);
        crypto.getRandomValues(array);
        const hex = Array.from(array).map(b => b.toString(16).padStart(2, '0')).join('').toUpperCase();
        const chunks = [];
        for (let i = 0; i < hex.length; i += 4) {
            chunks.push(hex.slice(i, i + 4));
        }
        return chunks.join('-');
    };

    const handleRegister = async () => {
        if (!username.trim()) return;
        setIsLoading(true);
        setError('');

        try {
            const rawSecret = generateSecretKey();
            const apiUrl = getApiUrl();

            const res = await fetch(`${apiUrl}/api/register`, {
                method: 'POST',
                headers: { 'Content-Type': 'application/json', 'ngrok-skip-browser-warning': 'true' },
                body: JSON.stringify({
                    username,
                    password: rawSecret,
                    deviceId: crypto.randomUUID(),
                    identityKey: 'v1'
                })
            });

            const data = await res.json();
            if (!res.ok) throw new Error(data.error || 'Registration failed');

            const decryptionKey = await deriveKeyFromPassphrase(rawSecret, username.toLowerCase().trim());
            const privateKey = await decryptPrivateKey(data.encryptedPrivateKey, decryptionKey);
            const publicKey = await importPublicKey(data.publicKey);

            try {
                const privJwk = await crypto.subtle.exportKey('jwk', privateKey);
                const pubJwk = await crypto.subtle.exportKey('jwk', publicKey);

                await saveSession({
                    userId: data.userId, username: data.username,
                    secureId: data.secureId, loginToken: data.token || data.loginToken,
                    privateKeyJwk: privJwk, publicKeyJwk: pubJwk,
                    secretKey: rawSecret
                });
            } catch (saveError) {
                console.warn('[Auth] Session save failed:', saveError);
            }

            // Gate entry behind one-time secret reveal (matches mobile restore model)
            setRevealedSecret(rawSecret);
            setPendingSuccess({
                userId: data.userId,
                username: data.username,
                secureId: data.secureId,
                loginToken: data.token || data.loginToken,
                keys: { privateKey, publicKey }
            });
            setStep('reveal');
            setSecretVisible(false);
            setCopied(false);
            setAckSaved(false);
        } catch (e: any) {
            console.error('[Auth] Registration error:', e);
            setError(e.message || 'Registration failed');
        } finally {
            setIsLoading(false);
        }
    };

    const handleLogin = async () => {
        if (!secretKey.trim()) return;
        setIsLoading(true);
        setError('');

        try {
            const cleanSecret = secretKey.trim().toUpperCase().replace(/[^A-F0-9-]/g, '');

            const res = await fetch(`${getApiUrl()}/api/login`, {
                method: 'POST',
                headers: { 'Content-Type': 'application/json', 'ngrok-skip-browser-warning': 'true' },
                body: JSON.stringify({
                    credential: cleanSecret,
                    password: cleanSecret,
                    deviceId: crypto.randomUUID()
                })
            });

            const data = await res.json();
            if (!res.ok) throw new Error(data.error || 'Login failed');
            if (!data.encryptedPrivateKey) throw new Error('Account does not support key sync. Please reset.');

            const decryptionKey = await deriveKeyFromPassphrase(cleanSecret, data.username.toLowerCase());
            const privateKey = await decryptPrivateKey(data.encryptedPrivateKey, decryptionKey);

            let pubKeyStr = data.publicKey;
            if (!pubKeyStr) {
                try {
                    const userRes = await fetch(`${getApiUrl()}/api/user/${data.userId}`);
                    if (userRes.ok) {
                        const userData = await userRes.json();
                        pubKeyStr = userData.publicKey;
                    }
                } catch (e) { console.warn('Failed fallback key fetch', e); }
            }

            if (!pubKeyStr) throw new Error('Could not retrieve public encryption key.');

            const publicKey = await importPublicKey(pubKeyStr);
            const privJwk = await crypto.subtle.exportKey('jwk', privateKey);
            const pubJwk = await crypto.subtle.exportKey('jwk', publicKey);

            await saveSession({
                userId: data.userId, username: data.username,
                secureId: data.secureId, loginToken: data.token || data.loginToken,
                privateKeyJwk: privJwk, publicKeyJwk: pubJwk,
                secretKey: cleanSecret
            });

            onSuccess({
                userId: data.userId, username: data.username, secureId: data.secureId,
                loginToken: data.token || data.loginToken, keys: { privateKey, publicKey }
            });
        } catch (e: any) {
            console.error('[Auth] Login Error:', e);
            setError(e.message || 'Login failed. Check your Secret Key.');
        } finally {
            setIsLoading(false);
        }
    };

    const handleCopySecret = async () => {
        try {
            await navigator.clipboard.writeText(revealedSecret);
            setCopied(true);
            setTimeout(() => setCopied(false), 2000);
        } catch {
            setError('Could not copy — select and copy the key manually.');
        }
    };

    const handleEnterApp = () => {
        if (!ackSaved || !pendingSuccess) return;
        onSuccess(pendingSuccess);
    };

    return (
        <div className="auth-container">
            <div className="auth-split">
                <section className="auth-form-side" aria-label="Authentication">
                    <div className="auth-form-inner">
                        <div className="auth-brand">
                            <svg width="22" height="22" viewBox="0 0 18 18" aria-hidden="true">
                                <circle cx="9" cy="9" r="7.4" fill="none" stroke="currentColor" strokeWidth="1.1" opacity="0.55" />
                                <circle cx="9" cy="9" r="2.4" fill="currentColor" />
                                <circle cx="14.6" cy="4.2" r="1.5" fill="currentColor" opacity="0.85" />
                            </svg>
                            <span>vibe</span>
                        </div>

                        <AnimatePresence mode="wait">
                            {step === 'reveal' ? (
                                <motion.div
                                    key="reveal"
                                    initial={panelInitial}
                                    animate={panelAnimate}
                                    exit={panelExit}
                                    transition={panelTransition}
                                    className="auth-content"
                                >
                                    <header className="auth-header">
                                        <h1 className="auth-title">Save your secret key</h1>
                                        <p className="auth-subtitle">
                                            This is your only key. Copy and store it somewhere safe.
                                            Anyone with this key can unlock your identity — we cannot recover it for you.
                                        </p>
                                    </header>

                                    <div className="auth-secret-box">
                                        <div className="auth-secret-label-row">
                                            <Shield size={14} aria-hidden="true" />
                                            <span>Secret key</span>
                                        </div>
                                        <div className="auth-secret-value" aria-live="polite">
                                            {secretVisible ? revealedSecret : '••••-••••-••••-••••-••••-••••-••••-••••'}
                                        </div>
                                        <div className="auth-secret-actions">
                                            <button
                                                type="button"
                                                className="auth-secret-action"
                                                onClick={() => setSecretVisible(v => !v)}
                                            >
                                                {secretVisible ? <EyeOff size={16} aria-hidden="true" /> : <Eye size={16} aria-hidden="true" />}
                                                {secretVisible ? 'Hide' : 'Reveal'}
                                            </button>
                                            <button
                                                type="button"
                                                className="auth-secret-action"
                                                onClick={handleCopySecret}
                                            >
                                                {copied ? <Check size={16} aria-hidden="true" /> : <Copy size={16} aria-hidden="true" />}
                                                {copied ? 'Copied' : 'Copy'}
                                            </button>
                                        </div>
                                    </div>

                                    <label className="auth-ack">
                                        <input
                                            type="checkbox"
                                            checked={ackSaved}
                                            onChange={e => setAckSaved(e.target.checked)}
                                        />
                                        <span>I saved my secret key somewhere safe</span>
                                    </label>

                                    <button
                                        type="button"
                                        className="auth-submit"
                                        disabled={!ackSaved}
                                        onClick={handleEnterApp}
                                    >
                                        Continue
                                    </button>

                                    {error && (
                                        <div className="auth-error" role="alert">
                                            {error}
                                        </div>
                                    )}
                                </motion.div>
                            ) : (
                                <motion.div
                                    key={formType}
                                    initial={panelInitial}
                                    animate={panelAnimate}
                                    exit={panelExit}
                                    transition={panelTransition}
                                    className="auth-content"
                                >
                                    {formType === 'register' ? (
                                        <>
                                            <header className="auth-header">
                                                <h1 className="auth-title">Create account</h1>
                                            </header>

                                            <form
                                                onSubmit={(e) => { e.preventDefault(); handleRegister(); }}
                                                className="auth-form"
                                            >
                                                <div className="auth-field">
                                                    <label htmlFor="auth-username">Username</label>
                                                    <input
                                                        id="auth-username"
                                                        type="text"
                                                        placeholder="Username"
                                                        autoComplete="username"
                                                        autoCapitalize="none"
                                                        value={username}
                                                        onChange={e => setUsername(e.target.value)}
                                                        disabled={isLoading}
                                                    />
                                                </div>

                                                <button
                                                    type="submit"
                                                    className="auth-submit"
                                                    disabled={isLoading || !username.trim()}
                                                >
                                                    {isLoading
                                                        ? <span className="auth-spinner" aria-label="Loading" />
                                                        : 'Create account'}
                                                </button>
                                            </form>

                                            <p className="auth-switch">
                                                <span>Already have an account?</span>
                                                <button
                                                    type="button"
                                                    className="auth-switch-link"
                                                    onClick={() => { setFormType('login'); setError(''); }}
                                                >
                                                    Sign in
                                                </button>
                                            </p>
                                        </>
                                    ) : (
                                        <>
                                            <header className="auth-header">
                                                <h1 className="auth-title">Sign in</h1>
                                            </header>

                                            <form
                                                onSubmit={(e) => { e.preventDefault(); handleLogin(); }}
                                                className="auth-form"
                                            >
                                                <div className="auth-field">
                                                    <label htmlFor="auth-secret">Secret key</label>
                                                    <input
                                                        id="auth-secret"
                                                        type="password"
                                                        placeholder="XXXX-XXXX-XXXX-…"
                                                        autoComplete="current-password"
                                                        spellCheck={false}
                                                        value={secretKey}
                                                        onChange={e => setSecretKey(e.target.value)}
                                                        disabled={isLoading}
                                                    />
                                                </div>

                                                <button
                                                    type="submit"
                                                    className="auth-submit"
                                                    disabled={isLoading || !secretKey.trim()}
                                                >
                                                    {isLoading
                                                        ? <span className="auth-spinner" aria-label="Loading" />
                                                        : 'Sign in'}
                                                </button>
                                            </form>

                                            <p className="auth-switch">
                                                <span>Need an account?</span>
                                                <button
                                                    type="button"
                                                    className="auth-switch-link"
                                                    onClick={() => { setFormType('register'); setError(''); }}
                                                >
                                                    Create account
                                                </button>
                                            </p>
                                        </>
                                    )}

                                    {error && (
                                        <div className="auth-error" role="alert">
                                            {error}
                                        </div>
                                    )}
                                </motion.div>
                            )}
                        </AnimatePresence>

                        <div className="auth-meta" aria-hidden="true">
                            <span>E2E · AES-256-GCM</span>
                            <span>Keys stay on device</span>
                        </div>
                    </div>
                </section>

                <aside className="auth-visual" aria-hidden="true">
                    <ContourField className="auth-shader" intensity={0.72} seed={3.7} />
                    <div className="auth-visual-veil" />
                    <div className="auth-visual-mark">
                        <svg width="36" height="36" viewBox="0 0 18 18">
                            <circle cx="9" cy="9" r="7.4" fill="none" stroke="currentColor" strokeWidth="0.9" opacity="0.45" />
                            <circle cx="9" cy="9" r="2.2" fill="currentColor" />
                            <circle cx="14.6" cy="4.2" r="1.35" fill="currentColor" opacity="0.8" />
                        </svg>
                    </div>
                </aside>
            </div>
        </div>
    );
};

export default Auth;
