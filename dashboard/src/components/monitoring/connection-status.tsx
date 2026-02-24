'use client';

import { useState, useEffect } from 'react';
import { Wifi, WifiOff, AlertTriangle } from 'lucide-react';
import { Card, CardContent } from '@/components/ui/card';
import { cn } from '@/lib/utils';
import type { ConnectionStatus } from '@/types/monitoring';

interface ConnectionStatusBannerProps {
  status: ConnectionStatus;
  lastUpdated?: Date | null;
  className?: string;
}

/**
 * Banner showing real-time connection status.
 * Only visible when there's a connection issue.
 */
export function ConnectionStatusBanner({
  status,
  lastUpdated,
  className,
}: ConnectionStatusBannerProps) {
  // Only show for error or disconnected states
  if (status === 'connected' || status === 'connecting') {
    return null;
  }

  const config = {
    disconnected: {
      icon: WifiOff,
      bg: 'bg-yellow-50 border-yellow-200',
      iconColor: 'text-yellow-600',
      textColor: 'text-yellow-800',
      title: 'Connection Lost',
      message: 'Real-time updates unavailable. Data may be stale.',
    },
    error: {
      icon: AlertTriangle,
      bg: 'bg-red-50 border-red-200',
      iconColor: 'text-red-600',
      textColor: 'text-red-800',
      title: 'Connection Error',
      message: 'Unable to establish real-time connection. Please check your network.',
    },
  };

  const { icon: Icon, bg, iconColor, textColor, title, message } = config[status];

  return (
    <Card className={cn('border', bg, className)}>
      <CardContent className="flex items-center gap-3 py-3">
        <Icon className={cn('h-5 w-5 flex-shrink-0', iconColor)} />
        <div className="flex-1">
          <p className={cn('text-sm font-medium', textColor)}>{title}</p>
          <p className={cn('text-xs', textColor, 'opacity-75')}>
            {message}
            {lastUpdated && (
              <span className="ml-1">
                Last update: {formatTimeAgo(lastUpdated)}
              </span>
            )}
          </p>
        </div>
      </CardContent>
    </Card>
  );
}

/**
 * Compact inline connection indicator for headers
 */
interface ConnectionIndicatorProps {
  status: ConnectionStatus;
  showLabel?: boolean;
  className?: string;
}

export function ConnectionIndicator({
  status,
  showLabel = true,
  className,
}: ConnectionIndicatorProps) {
  const config: Record<
    ConnectionStatus,
    { icon: typeof Wifi; color: string; label: string; animate?: boolean }
  > = {
    connected: {
      icon: Wifi,
      color: 'text-green-600',
      label: 'Live',
    },
    connecting: {
      icon: Wifi,
      color: 'text-yellow-600',
      label: 'Connecting...',
      animate: true,
    },
    disconnected: {
      icon: WifiOff,
      color: 'text-slate-400',
      label: 'Offline',
    },
    error: {
      icon: WifiOff,
      color: 'text-red-600',
      label: 'Error',
    },
  };

  const { icon: Icon, color, label, animate } = config[status];

  return (
    <div className={cn('flex items-center gap-1.5 text-sm', color, className)}>
      <Icon className={cn('h-4 w-4', animate && 'animate-pulse')} />
      {showLabel && <span>{label}</span>}
    </div>
  );
}

/**
 * Hook for detecting network online/offline status
 */
export function useNetworkStatus() {
  const [isOnline, setIsOnline] = useState(true);

  useEffect(() => {
    // Check initial status
    setIsOnline(navigator.onLine);

    const handleOnline = () => setIsOnline(true);
    const handleOffline = () => setIsOnline(false);

    window.addEventListener('online', handleOnline);
    window.addEventListener('offline', handleOffline);

    return () => {
      window.removeEventListener('online', handleOnline);
      window.removeEventListener('offline', handleOffline);
    };
  }, []);

  return isOnline;
}

/**
 * Banner that appears when the browser goes offline
 */
export function OfflineBanner() {
  const isOnline = useNetworkStatus();

  if (isOnline) {
    return null;
  }

  return (
    <div className="fixed bottom-4 left-1/2 -translate-x-1/2 z-50">
      <Card className="bg-slate-900 text-white shadow-lg">
        <CardContent className="flex items-center gap-3 py-3 px-4">
          <WifiOff className="h-5 w-5 text-yellow-400" />
          <div>
            <p className="text-sm font-medium">You&apos;re offline</p>
            <p className="text-xs text-slate-400">
              Check your internet connection
            </p>
          </div>
        </CardContent>
      </Card>
    </div>
  );
}

// Helper function
function formatTimeAgo(date: Date): string {
  const seconds = Math.floor((Date.now() - date.getTime()) / 1000);

  if (seconds < 5) return 'just now';
  if (seconds < 60) return `${seconds}s ago`;

  const minutes = Math.floor(seconds / 60);
  if (minutes < 60) return `${minutes}m ago`;

  const hours = Math.floor(minutes / 60);
  return `${hours}h ago`;
}
