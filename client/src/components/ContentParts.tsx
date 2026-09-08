/**
 * vibe.content.v1 parts renderer for message bubbles.
 *
 * Renders structured parts the existing bubble text/media path does not own:
 * card, actions, citations, status, error, vibe.call.
 * text/media → null (bubble already shows those). Unknown kinds → text lane.
 * Tolerant parsing: never crash on malformed metadata.
 */
import React, { useMemo } from 'react';
import './ContentParts.css';

// ── Public types (loose; runtime-validated) ─────────────────────────────────

export type ContentPartsProps = {
  /** Raw `vibe.content.v1` envelope (or unknown). */
  content: unknown;
  /** Host accent color (CSS color string). */
  accent: string;
  /** Action button/select id — host wires events POST later. */
  onAction: (id: string) => void;
  /** Call CTA tap — host wires call.requested later. */
  onCall: () => void;
};

type PartFrame = {
  kind: string;
  schemaVersion: number;
  text: string;
  data: Record<string, unknown>;
  mediaType: string | null;
  url: string | null;
  required: boolean;
};

// ── Safe helpers ────────────────────────────────────────────────────────────

function isRecord(v: unknown): v is Record<string, unknown> {
  return typeof v === 'object' && v !== null && !Array.isArray(v);
}

function asString(v: unknown): string | null {
  if (typeof v === 'string') return v;
  if (typeof v === 'number' && Number.isFinite(v)) return String(v);
  if (typeof v === 'boolean') return v ? 'true' : 'false';
  return null;
}

function asNumber(v: unknown): number | null {
  if (typeof v === 'number' && Number.isFinite(v)) return v;
  if (typeof v === 'string' && v.trim() !== '') {
    const n = Number(v);
    return Number.isFinite(n) ? n : null;
  }
  return null;
}

function asBool(v: unknown): boolean | null {
  if (typeof v === 'boolean') return v;
  return null;
}

function parsePart(raw: unknown): PartFrame | null {
  if (!isRecord(raw)) return null;
  const kind = (asString(raw.kind) ?? '').trim();
  if (!kind) return null;
  const schemaRaw = asNumber(raw.schemaVersion);
  const schemaVersion = schemaRaw !== null && schemaRaw >= 1 ? Math.floor(schemaRaw) : 1;
  const text = asString(raw.text) ?? '';
  const data = isRecord(raw.data) ? raw.data : {};
  const mediaType = asString(raw.mediaType);
  const url = asString(raw.url);
  const required = asBool(raw.required) ?? false;
  return { kind, schemaVersion, text, data, mediaType, url, required };
}

function parseParts(content: unknown): PartFrame[] {
  if (!isRecord(content)) return [];
  if (content.contract !== 'vibe.content.v1') return [];
  const rawParts = content.parts;
  if (!Array.isArray(rawParts)) return [];
  const out: PartFrame[] = [];
  for (const item of rawParts) {
    const p = parsePart(item);
    if (p) out.push(p);
  }
  return out;
}

function domainFromUrl(href: string): string | null {
  try {
    const u = new URL(href);
    return u.hostname.replace(/^www\./, '') || null;
  } catch {
    return null;
  }
}

function openExternal(href: string): void {
  try {
    const u = new URL(href);
    if (u.protocol === 'http:' || u.protocol === 'https:') {
      window.open(u.toString(), '_blank', 'noopener,noreferrer');
    }
  } catch {
    // ignore malformed
  }
}

// ── Kind views ──────────────────────────────────────────────────────────────

function CardPart({ part, accent }: { part: PartFrame; accent: string }) {
  const title = asString(part.data.title);
  const subtitle = asString(part.data.subtitle);
  const link = asString(part.data.link);
  const fieldsRaw = Array.isArray(part.data.fields) ? part.data.fields : [];
  const fields = fieldsRaw
    .map((f) => {
      if (!isRecord(f)) return null;
      const label = asString(f.label) ?? '';
      const value = asString(f.value) ?? '';
      if (!label && !value) return null;
      return { label, value };
    })
    .filter((x): x is { label: string; value: string } => x !== null);

  const hasHeader = !!(title && title.trim()) || !!(subtitle && subtitle.trim());
  const domain = link ? domainFromUrl(link) : null;

  return (
    <div className="vibe-cp-card">
      {title && title.trim() ? (
        <div className="vibe-cp-card-title">{title}</div>
      ) : null}
      {subtitle && subtitle.trim() ? (
        <div className="vibe-cp-card-subtitle" style={{ color: accent }}>
          {subtitle}
        </div>
      ) : null}
      {!hasHeader && part.text ? (
        <div className="vibe-cp-text-lane">{part.text}</div>
      ) : null}
      {fields.length > 0 ? (
        <div className="vibe-cp-card-fields">
          {fields.map((f, i) => (
            <div key={i} className="vibe-cp-card-field">
              <span className="vibe-cp-card-field-label">{f.label}</span>
              <span className="vibe-cp-card-field-value">{f.value}</span>
            </div>
          ))}
        </div>
      ) : null}
      {link ? (
        <button
          type="button"
          className="vibe-cp-card-link"
          style={{ color: accent, background: `${accent}1F` }}
          onClick={(e) => {
            e.stopPropagation();
            openExternal(link);
          }}
        >
          <span className="vibe-cp-card-link-label">{domain ?? 'Open link'}</span>
          <span className="vibe-cp-card-link-chevron" aria-hidden>
            ›
          </span>
        </button>
      ) : null}
    </div>
  );
}

type ActionItem = {
  id: string;
  label: string;
  style: string;
  kind: string;
  options: { id: string; label: string }[];
};

function parseActionItems(data: Record<string, unknown>): ActionItem[] {
  const raw = Array.isArray(data.items) ? data.items : [];
  const out: ActionItem[] = [];
  for (const item of raw) {
    if (!isRecord(item)) continue;
    const id = asString(item.id) ?? '';
    const label = asString(item.label) ?? id;
    if (!id || !label) continue;
    const style = (asString(item.style) ?? 'default').toLowerCase();
    const kind = (asString(item.kind) ?? 'button').toLowerCase();
    const optionsRaw = Array.isArray(item.options) ? item.options : [];
    const options = optionsRaw
      .map((o) => {
        if (!isRecord(o)) return null;
        const oid = asString(o.id) ?? '';
        const olabel = asString(o.label) ?? oid;
        if (!oid || !olabel) return null;
        return { id: oid, label: olabel };
      })
      .filter((x): x is { id: string; label: string } => x !== null);
    out.push({ id, label, style, kind, options });
  }
  return out;
}

function actionStyleClass(style: string): string {
  if (style === 'primary') return 'vibe-cp-action--primary';
  if (style === 'danger' || style === 'destructive') return 'vibe-cp-action--danger';
  return 'vibe-cp-action--default';
}

function ActionsPart({
  part,
  accent,
  onAction,
}: {
  part: PartFrame;
  accent: string;
  onAction: (id: string) => void;
}) {
  const items = parseActionItems(part.data);
  if (items.length === 0) {
    return part.text ? <div className="vibe-cp-text-lane vibe-cp-muted">{part.text}</div> : null;
  }

  return (
    <div className="vibe-cp-actions">
      {items.map((item) => {
        if (item.kind === 'select' && item.options.length > 0) {
          return (
            <label key={item.id} className={`vibe-cp-action vibe-cp-action--select ${actionStyleClass(item.style)}`}>
              <span className="vibe-cp-action-label">{item.label}</span>
              <select
                className="vibe-cp-action-select"
                defaultValue=""
                style={{ ['--vibe-cp-accent' as string]: accent }}
                onClick={(e) => e.stopPropagation()}
                onChange={(e) => {
                  e.stopPropagation();
                  const v = e.target.value;
                  if (v) onAction(v);
                  e.target.value = '';
                }}
                aria-label={item.label}
              >
                <option value="" disabled>
                  Choose…
                </option>
                {item.options.map((o) => (
                  <option key={o.id} value={o.id}>
                    {o.label}
                  </option>
                ))}
              </select>
            </label>
          );
        }
        const isPrimary = item.style === 'primary';
        return (
          <button
            key={item.id}
            type="button"
            className={`vibe-cp-action ${actionStyleClass(item.style)}`}
            style={
              isPrimary
                ? { background: accent, borderColor: accent, color: '#fff' }
                : item.style === 'danger' || item.style === 'destructive'
                  ? undefined
                  : { color: accent, borderColor: `${accent}8C` }
            }
            onClick={(e) => {
              e.stopPropagation();
              onAction(item.id);
            }}
          >
            {item.label}
          </button>
        );
      })}
    </div>
  );
}

function CitationsPart({ part, accent }: { part: PartFrame; accent: string }) {
  const raw = Array.isArray(part.data.items) ? part.data.items : [];
  const items = raw
    .map((item) => {
      if (!isRecord(item)) return null;
      const title = asString(item.title) ?? '';
      const url = asString(item.url);
      const snippet = asString(item.snippet);
      if (!title && !url) return null;
      return { title, url, snippet };
    })
    .filter((x): x is { title: string; url: string | null; snippet: string | null } => x !== null);

  if (items.length === 0) {
    return part.text ? <div className="vibe-cp-text-lane vibe-cp-muted">{part.text}</div> : null;
  }

  return (
    <div className="vibe-cp-citations">
      <div className="vibe-cp-section-label">Sources</div>
      <div className="vibe-cp-citation-list">
        {items.map((item, i) => {
          const domain = item.url ? domainFromUrl(item.url) : null;
          const clickable = !!item.url;
          const body = (
            <>
              <span className="vibe-cp-citation-index" style={{ color: accent, background: `${accent}29` }}>
                {i + 1}
              </span>
              <span className="vibe-cp-citation-meta">
                <span className="vibe-cp-citation-title">
                  {item.title || domain || 'Source'}
                </span>
                {domain ? <span className="vibe-cp-citation-domain">{domain}</span> : null}
              </span>
            </>
          );
          if (clickable && item.url) {
            return (
              <button
                key={i}
                type="button"
                className="vibe-cp-citation"
                onClick={(e) => {
                  e.stopPropagation();
                  openExternal(item.url!);
                }}
              >
                {body}
              </button>
            );
          }
          return (
            <div key={i} className="vibe-cp-citation vibe-cp-citation--static">
              {body}
            </div>
          );
        })}
      </div>
    </div>
  );
}

function StatusPart({ part, accent }: { part: PartFrame; accent: string }) {
  const state = (asString(part.data.state) ?? '').toLowerCase();
  const label = asString(part.data.label) ?? part.text;
  const progressRaw = asNumber(part.data.progress);
  const progress =
    progressRaw !== null ? Math.min(1, Math.max(0, progressRaw)) : null;
  const isDone = state === 'done';
  const isError = state === 'error';
  const isActive =
    state === 'thinking' || state === 'tool_running' || state === 'generating';

  return (
    <div className="vibe-cp-status">
      <div className="vibe-cp-status-leading" aria-hidden>
        {isDone ? (
          <span className="vibe-cp-status-icon vibe-cp-status-icon--done">✓</span>
        ) : isError ? (
          <span className="vibe-cp-status-icon vibe-cp-status-icon--warn">!</span>
        ) : progress !== null ? (
          <span
            className="vibe-cp-status-ring"
            style={
              {
                ['--vibe-cp-accent' as string]: accent,
                ['--vibe-cp-progress' as string]: String(progress),
              } as React.CSSProperties
            }
          />
        ) : isActive ? (
          <span className="vibe-cp-status-spinner" style={{ borderTopColor: accent }} />
        ) : (
          <span className="vibe-cp-status-icon vibe-cp-status-icon--idle">…</span>
        )}
      </div>
      <div className="vibe-cp-status-body">
        <div className={`vibe-cp-status-label ${isError ? 'vibe-cp-status-label--error' : ''}`}>
          {label && label.trim() ? label : part.text}
        </div>
        {progress !== null && !isDone ? (
          <div className="vibe-cp-status-bar">
            <div
              className="vibe-cp-status-bar-fill"
              style={{
                width: `${Math.max(4, progress * 100)}%`,
                background: isError ? 'var(--vibe-cp-warning)' : accent,
              }}
            />
          </div>
        ) : null}
      </div>
    </div>
  );
}

function ErrorPart({ part }: { part: PartFrame }) {
  const code = (asString(part.data.code) ?? '').toLowerCase();
  const message = asString(part.data.message) ?? part.text;
  const retryable = asBool(part.data.retryable) ?? code !== 'refusal';
  const isRefusal = code === 'refusal';
  const caption = isRefusal
    ? 'Request declined'
    : retryable
      ? 'Something went wrong — you can try again'
      : 'Error';

  return (
    <div
      className={`vibe-cp-error ${isRefusal ? 'vibe-cp-error--refusal' : 'vibe-cp-error--hard'}`}
    >
      <div className="vibe-cp-error-caption">{caption}</div>
      <div className="vibe-cp-error-message">
        {message && message.trim() ? message : part.text}
      </div>
    </div>
  );
}

function CallPart({
  part,
  accent,
  onCall,
}: {
  part: PartFrame;
  accent: string;
  onCall: () => void;
}) {
  const fromData = (asString(part.data.label) ?? '').trim();
  const fromText = part.text.trim();
  const label = fromData || fromText || 'Start call';

  return (
    <button
      type="button"
      className="vibe-cp-call"
      style={{
        background: `linear-gradient(135deg, ${accent} 0%, ${accent}D1 100%)`,
      }}
      onClick={(e) => {
        e.stopPropagation();
        onCall();
      }}
      aria-label={label}
    >
      <span className="vibe-cp-call-icon" aria-hidden>
        ☎
      </span>
      <span className="vibe-cp-call-label">{label}</span>
      <span className="vibe-cp-call-chevron" aria-hidden>
        ›
      </span>
    </button>
  );
}

function UnknownPart({ part }: { part: PartFrame }) {
  const body = part.text.trim();
  return (
    <div className="vibe-cp-unknown">
      {part.required ? (
        <div className="vibe-cp-needs-app">Needs a newer app to fully display</div>
      ) : null}
      {body ? <div className="vibe-cp-text-lane">{body}</div> : null}
    </div>
  );
}

function PartRow({
  part,
  accent,
  onAction,
  onCall,
}: {
  part: PartFrame;
  accent: string;
  onAction: (id: string) => void;
  onCall: () => void;
}) {
  switch (part.kind) {
    case 'text':
    case 'media':
      // Bubble already owns body text + media attachments.
      return null;
    case 'card':
      return <CardPart part={part} accent={accent} />;
    case 'actions':
      return <ActionsPart part={part} accent={accent} onAction={onAction} />;
    case 'citations':
      return <CitationsPart part={part} accent={accent} />;
    case 'status':
      return <StatusPart part={part} accent={accent} />;
    case 'error':
      return <ErrorPart part={part} />;
    case 'vibe.call':
      return <CallPart part={part} accent={accent} onCall={onCall} />;
    default:
      return <UnknownPart part={part} />;
  }
}

// ── Root ────────────────────────────────────────────────────────────────────

/**
 * Renders rich `vibe.content.v1` parts under bubble text.
 * Returns null if content is missing, wrong contract, or has nothing to show.
 */
export default function ContentParts({
  content,
  accent,
  onAction,
  onCall,
}: ContentPartsProps) {
  const parts = useMemo(() => {
    try {
      return parseParts(content);
    } catch {
      return [] as PartFrame[];
    }
  }, [content]);

  const nodes = useMemo(() => {
    try {
      return parts
        .map((part, i) => (
          <PartRow
            key={`${part.kind}-${i}`}
            part={part}
            accent={accent}
            onAction={onAction}
            onCall={onCall}
          />
        ))
        .filter((n) => n !== null);
    } catch {
      return [] as React.ReactNode[];
    }
  }, [parts, accent, onAction, onCall]);

  if (!nodes.length) return null;

  return (
    <div
      className="vibe-content-parts"
      style={{ ['--vibe-cp-accent' as string]: accent }}
      onClick={(e) => e.stopPropagation()}
      onDoubleClick={(e) => e.stopPropagation()}
    >
      {nodes}
    </div>
  );
}

/** True when message.metadata.content is a vibe.content.v1 envelope. */
export function hasVibeContentV1(message: {
  metadata?: { content?: { contract?: string } | unknown } | unknown;
}): boolean {
  try {
    const meta = message?.metadata;
    if (!isRecord(meta)) return false;
    const content = meta.content;
    if (!isRecord(content)) return false;
    return content.contract === 'vibe.content.v1';
  } catch {
    return false;
  }
}

/** Safe extract of metadata.content when contract matches. */
export function getVibeContentEnvelope(message: {
  metadata?: { content?: unknown } | unknown;
}): unknown | null {
  try {
    if (!hasVibeContentV1(message as { metadata?: { content?: { contract?: string } } })) {
      return null;
    }
    const meta = (message as { metadata?: { content?: unknown } }).metadata;
    return isRecord(meta) ? meta.content ?? null : null;
  } catch {
    return null;
  }
}
