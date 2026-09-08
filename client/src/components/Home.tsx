import React, { useMemo, useState } from 'react';
import { motion, AnimatePresence, useMotionValue, useTransform, useAnimation, animate } from 'framer-motion';
import { useDrag } from '@use-gesture/react';
import { Trash2, Pin, VolumeX, Copy, Ghost } from 'lucide-react';
import { Chat } from '../types';
import {
    avatarGradientCss,
    avatarInitials,
    chatLastTimestamp,
    chatPreviewText,
    formatChatListTime,
} from '../theme/appearance';
import HomeHeader from './HomeHeader';
import './Home.css';
import Haptics from '../haptics';

interface ChatListProps {
    isEditing: boolean;
    setIsEditing: (is: boolean) => void;
    connectionStatus: string;
    setView: (view: string) => void;
    areChatsLoading: boolean;
    chats: Chat[];
    userId: string;
    openChat: (chat: Chat) => void;
    deleteChat: (chatId: string) => void;
    typingUsers: Set<string>;
    setShowNewChatModal: (show: boolean) => void;
    toast: string | null;
    chatOptionsChat: Chat | null;
    setChatOptionsChat: (chat: Chat | null) => void;
    clearChat: (chatId: string) => void;
    pinChat: (chatId: string) => void;
    toggleMute: (chatId: string) => void;
    username: string;
}

const SwipeableChatRow = ({
    chat,
    isEditing,
    userId,
    typingUsers,
    onOpen,
    onDelete,
    onPin,
    onContextMenu
}: {
    chat: Chat;
    isEditing: boolean;
    userId: string;
    typingUsers: Set<string>;
    onOpen: () => void;
    onDelete: () => void;
    onPin: () => void;
    onContextMenu: (e: React.MouseEvent | null, rect?: DOMRect) => void;
}) => {
    const x = useMotionValue(0);
    const controls = useAnimation();
    const seed = chat.friendId || chat.friendName || chat.chatId;
    const preview = chatPreviewText(chat, userId);
    const ts = chatLastTimestamp(chat);
    const isTyping = typingUsers.has(chat.friendId?.toUpperCase());

    const bgInfo = useTransform(x, [-100, -30, 0, 30, 100], [
        'rgba(239, 68, 68, 1)',
        'rgba(239, 68, 68, 0)',
        'rgba(0,0,0,0)',
        'rgba(59, 130, 246, 0)',
        'rgba(59, 130, 246, 1)'
    ]);

    const iconOpacity = useTransform(x, [-60, -20, 0, 20, 60], [1, 0, 0, 0, 1]);
    const iconScale = useTransform(x, [-120, -60, 0, 60, 120], [1.5, 1, 0.5, 1, 1.5]);

    const longPressTimer = React.useRef<ReturnType<typeof setTimeout> | null>(null);

    const clearLongPress = () => {
        if (longPressTimer.current) {
            clearTimeout(longPressTimer.current);
            longPressTimer.current = null;
        }
    };

    const bind = useDrag(({ active, first, movement: [mx, my], cancel, event }) => {
        const e = event as unknown as React.PointerEvent;

        if (first) {
            clearLongPress();
            const target = e?.currentTarget as HTMLElement;
            if (target) {
                longPressTimer.current = setTimeout(() => {
                    try { Haptics.medium(); } catch { /* ignore */ }
                    const rect = target.getBoundingClientRect();
                    onContextMenu(null, rect);
                }, 400);
            }
        }

        if (active && (Math.abs(mx) > 10 || Math.abs(my) > 10)) {
            clearLongPress();
        }

        if (active && Math.abs(my) > Math.abs(mx) * 1.5) {
            cancel();
            clearLongPress();
            return;
        }

        if (active) {
            if (mx > 60 && x.get() <= 60) Haptics.medium();
            if (mx < -60 && x.get() >= -60) Haptics.medium();
            x.set(mx);
        } else {
            clearLongPress();

            if (Math.abs(mx) < 10 && Math.abs(my) < 10) {
                if (isEditing) onDelete();
                else onOpen();
            } else if (mx < -60) {
                Haptics.error();
                if (window.confirm('Delete this chat?')) onDelete();
                controls.start({ x: 0 });
            } else if (mx > 60) {
                Haptics.success();
                onPin();
                controls.start({ x: 0 });
            } else {
                animate(x, 0, { type: 'spring', stiffness: 400, damping: 30 });
            }
        }
    }, {
        axis: 'x',
        filterTaps: true,
        threshold: 5,
        pointer: { touch: true }
    });

    return (
        <motion.div layout className="chat-row-wrapper">
            <motion.div className="chat-row-bg-actions" style={{ background: bgInfo }}>
                <motion.div style={{ display: 'flex', alignItems: 'center', color: '#fff', opacity: iconOpacity, scale: iconScale, x: 20 }}>
                    <Pin size={24} fill="white" />
                </motion.div>
                <motion.div style={{ display: 'flex', alignItems: 'center', color: '#fff', opacity: iconOpacity, scale: iconScale, x: -20 }}>
                    <Trash2 size={24} />
                </motion.div>
            </motion.div>

            <motion.div
                className={`chat-row-card${chat.unreadCount ? ' has-unread' : ''}${chat.pinned ? ' is-pinned' : ''}`}
                style={{ x, touchAction: 'pan-y' }}
                {...(bind() as any)}
                animate={controls}
                whileTap={{ scale: 0.99 }}
                onContextMenu={(e) => {
                    e.preventDefault();
                    onContextMenu(e);
                }}
            >
                {isEditing && (
                    <div className="chat-row-edit">
                        <button type="button" onClick={(e) => { e.stopPropagation(); onDelete(); }} className="edit-delete-btn">
                            <Trash2 size={14} />
                        </button>
                    </div>
                )}

                <div className="avatar-container">
                    {chat.friendImage ? (
                        <div className="avatar avatar--image">
                            <img src={chat.friendImage} alt="" />
                        </div>
                    ) : (
                        <div
                            className="avatar"
                            style={{ background: avatarGradientCss(seed) }}
                        >
                            {avatarInitials(chat.friendName || '?')}
                        </div>
                    )}
                    {isTyping && <div className="online-badge" title="Typing" />}
                </div>

                <div className="chat-row-content">
                    <div className="chat-name-row">
                        <span className="chat-name-text">{chat.friendName || 'Chat'}</span>
                        {chat.pinned && (
                            <Pin size={12} className="chat-name-pin" fill="currentColor" />
                        )}
                    </div>
                    <div className="chat-status-text">
                        {isTyping ? (
                            <span className="typing-shine">typing…</span>
                        ) : (
                            <span className="chat-preview-text">{preview}</span>
                        )}
                    </div>
                </div>

                <div className="chat-row-meta-col">
                    <span className={`chat-time-text${chat.unreadCount ? ' unread' : ''}`}>
                        {formatChatListTime(ts)}
                    </span>
                    <div className="chat-row-icons">
                        {chat.muted && <VolumeX size={14} className="chat-meta-icon" />}
                        {chat.unreadCount ? (
                            <div className={`unread-badge${chat.muted ? ' muted' : ''}`}>
                                {chat.unreadCount > 99 ? '99+' : chat.unreadCount}
                            </div>
                        ) : null}
                    </div>
                </div>
            </motion.div>
        </motion.div>
    );
};

const Home: React.FC<ChatListProps> = ({
    isEditing, setIsEditing, connectionStatus, setView, areChatsLoading,
    chats, userId, openChat, deleteChat, typingUsers, setShowNewChatModal,
    toast, pinChat, toggleMute
}) => {
    const [contextMenu, setContextMenu] = useState<{
        chatId: string;
        rect: DOMRect;
    } | null>(null);

    // Stable order: pinned first, then by last activity (matches Chat.tsx / mobile)
    const orderedChats = useMemo(() => {
        return [...chats].sort((a, b) => {
            if (a.pinned && !b.pinned) return -1;
            if (!a.pinned && b.pinned) return 1;
            return chatLastTimestamp(b) - chatLastTimestamp(a);
        });
    }, [chats]);

    const handleContextMenu = (e: React.MouseEvent | React.PointerEvent | null, chatId: string, manualRect?: DOMRect) => {
        if (e) e.preventDefault();
        let rect: DOMRect;
        if (manualRect) {
            rect = manualRect;
        } else if (e) {
            const target = e.currentTarget as HTMLElement;
            rect = target.getBoundingClientRect();
        } else {
            return;
        }
        setContextMenu({ chatId, rect });
        try {
            if (navigator.vibrate) navigator.vibrate(50);
        } catch {
            /* ignore */
        }
    };

    const closeContextMenu = () => setContextMenu(null);

    return (
        <div className="home-view-container" onClick={closeContextMenu}>
            <div className="home-header-fixed">
                <HomeHeader
                    connectionStatus={connectionStatus}
                    setView={setView}
                    setShowNewChatModal={setShowNewChatModal}
                    isEditing={isEditing}
                    setIsEditing={setIsEditing}
                />
            </div>

            <div className="home-scroll-container">
                {areChatsLoading && orderedChats.length === 0 ? (
                    <div className="home-skeleton-list">
                        {[1, 2, 3, 4, 5].map(i => (
                            <div key={i} className="home-skeleton-row">
                                <div className="home-skeleton-avatar" />
                                <div className="home-skeleton-lines">
                                    <div className="home-skeleton-line short" />
                                    <div className="home-skeleton-line long" />
                                </div>
                            </div>
                        ))}
                    </div>
                ) : orderedChats.length === 0 ? (
                    <div className="empty-state fade-in">
                        <motion.div
                            animate={{ y: [0, -10, 0] }}
                            transition={{ repeat: Infinity, duration: 3, ease: 'easeInOut' }}
                            className="empty-state-icon"
                        >
                            <Ghost size={96} strokeWidth={1} color="var(--text-secondary)" />
                        </motion.div>

                        <p className="empty-state-title">Waiting for a friend?</p>
                        <p className="empty-state-sub">Start a chat with a username or secure ID.</p>

                        <motion.button
                            whileHover={{ scale: 1.03 }}
                            whileTap={{ scale: 0.97 }}
                            onClick={() => setShowNewChatModal(true)}
                            className="empty-state-cta"
                        >
                            Start Vibing
                        </motion.button>
                    </div>
                ) : (
                    <div className="home-chat-list">
                        {orderedChats.map(c => (
                            <SwipeableChatRow
                                key={c.chatId}
                                chat={c}
                                isEditing={isEditing}
                                userId={userId}
                                typingUsers={typingUsers}
                                onOpen={() => openChat(c)}
                                onDelete={() => deleteChat(c.chatId)}
                                onPin={() => pinChat(c.chatId)}
                                onContextMenu={(e, rect) => handleContextMenu(e, c.chatId, rect)}
                            />
                        ))}
                    </div>
                )}
            </div>

            {toast && (
                <div className="home-toast-anchor">
                    <div className="toast-notification">{toast}</div>
                </div>
            )}

            <AnimatePresence>
                {contextMenu && (() => {
                    const activeMenuChat = orderedChats.find(c => c.chatId === contextMenu.chatId);
                    if (!activeMenuChat) return null;
                    const seed = activeMenuChat.friendId || activeMenuChat.friendName || activeMenuChat.chatId;
                    const preview = chatPreviewText(activeMenuChat, userId);
                    const ts = chatLastTimestamp(activeMenuChat);

                    return (
                        <motion.div
                            initial={{ opacity: 0 }}
                            animate={{ opacity: 1 }}
                            exit={{ opacity: 0 }}
                            className="context-menu-overlay"
                            onClick={closeContextMenu}
                        >
                            <div className="cloned-bubble-wrapper" style={{ top: 0, left: 0, width: '100%', height: '100%' }}>
                                <motion.div
                                    initial={{
                                        top: contextMenu.rect.top,
                                        left: contextMenu.rect.left,
                                        width: contextMenu.rect.width,
                                        height: contextMenu.rect.height,
                                        scale: 1,
                                    }}
                                    animate={{
                                        scale: 1.02,
                                        borderRadius: 12,
                                        boxShadow: '0 20px 60px rgba(0,0,0,0.5)',
                                        zIndex: 2002
                                    }}
                                    exit={{ scale: 1, opacity: 0 }}
                                    className="cloned-bubble-content"
                                    style={{ position: 'absolute', overflow: 'hidden', userSelect: 'none' }}
                                >
                                    <div className="chat-row-card" style={{ padding: '12px 16px', background: 'var(--bg-primary)' }}>
                                        <div className="avatar-container">
                                            {activeMenuChat.friendImage ? (
                                                <div className="avatar avatar--image">
                                                    <img src={activeMenuChat.friendImage} alt="" />
                                                </div>
                                            ) : (
                                                <div className="avatar" style={{ background: avatarGradientCss(seed) }}>
                                                    {avatarInitials(activeMenuChat.friendName || '?')}
                                                </div>
                                            )}
                                        </div>
                                        <div className="chat-row-content">
                                            <span className="chat-name-text">{activeMenuChat.friendName}</span>
                                            <div className="chat-status-text">
                                                <span className="chat-preview-text">{preview}</span>
                                            </div>
                                        </div>
                                        <div className="chat-row-meta-col">
                                            <span className="chat-time-text">{formatChatListTime(ts)}</span>
                                            {activeMenuChat.unreadCount ? (
                                                <div className="unread-badge">{activeMenuChat.unreadCount}</div>
                                            ) : null}
                                        </div>
                                    </div>
                                </motion.div>

                                <motion.div
                                    initial={{ opacity: 0, scale: 0.95 }}
                                    animate={{ opacity: 1, scale: 1 }}
                                    exit={{ opacity: 0, scale: 0.95 }}
                                    className="context-menu-container"
                                    style={{
                                        position: 'absolute',
                                        width: 240,
                                        top: Math.min(contextMenu.rect.bottom + 10, window.innerHeight - 220),
                                        left: (window.innerWidth - 240) / 2
                                    }}
                                    onClick={(e) => e.stopPropagation()}
                                >
                                    <button type="button" className="context-menu-item" onClick={() => {
                                        navigator.clipboard.writeText(
                                            activeMenuChat.previewLastMessage
                                            || activeMenuChat.messages[activeMenuChat.messages.length - 1]?.plaintext
                                            || ''
                                        );
                                        closeContextMenu();
                                    }}>
                                        <Copy size={20} strokeWidth={1.5} /> <span>Copy Preview</span>
                                    </button>

                                    <button type="button" className="context-menu-item" onClick={(e) => {
                                        e.stopPropagation();
                                        toggleMute(contextMenu.chatId);
                                        closeContextMenu();
                                    }}>
                                        <VolumeX size={20} strokeWidth={1.5} /> <span>{activeMenuChat.muted ? 'Unmute' : 'Mute'}</span>
                                    </button>

                                    <button type="button" className="context-menu-item" onClick={(e) => {
                                        e.stopPropagation();
                                        pinChat(contextMenu.chatId);
                                        closeContextMenu();
                                    }}>
                                        <Pin size={20} strokeWidth={1.5} /> <span>{activeMenuChat.pinned ? 'Unpin' : 'Pin'}</span>
                                    </button>

                                    <div className="context-menu-divider" />

                                    <button type="button" className="context-menu-item danger" onClick={(e) => {
                                        e.stopPropagation();
                                        if (confirm('Delete this chat?')) deleteChat(contextMenu.chatId);
                                        closeContextMenu();
                                    }}>
                                        <Trash2 size={20} strokeWidth={1.5} /> <span>Delete Chat</span>
                                    </button>
                                </motion.div>
                            </div>
                        </motion.div>
                    );
                })()}
            </AnimatePresence>
        </div>
    );
};

export default Home;
