'use client';

import { useState, useEffect } from 'react';
import Link from 'next/link';
import { useLogout, useGetIdentity } from '@refinedev/core';
import { LogOut, Menu, User, Bell, FileText } from 'lucide-react';
import { Button } from '@/components/ui/button';
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuLabel,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
} from '@/components/ui/dropdown-menu';
import { supabaseClient } from '@/lib/supabase/client';
import type { UserIdentity } from '@/types/dashboard';
import type { PendingNotification } from '@/types/reports';

export function Header() {
  const { mutate: logout } = useLogout();
  const { data: user } = useGetIdentity<UserIdentity>();
  const [notifications, setNotifications] = useState<PendingNotification[]>([]);
  const [notificationCount, setNotificationCount] = useState(0);

  // Fetch pending report notifications
  useEffect(() => {
    async function fetchNotifications() {
      try {
        const { data, error } = await supabaseClient.rpc('get_pending_report_notifications');
        if (data && !error) {
          const response = data as { count: number; items: PendingNotification[] };
          setNotificationCount(response.count || 0);
          setNotifications(response.items || []);
        }
      } catch {
        // Silently fail - notifications are not critical
      }
    }

    fetchNotifications();
    // Refresh every 60 seconds
    const interval = setInterval(fetchNotifications, 60000);
    return () => clearInterval(interval);
  }, []);

  // Mark notification as seen
  const markAsSeen = async (jobId: string) => {
    try {
      await supabaseClient.rpc('mark_report_notification_seen', { p_job_id: jobId });
      setNotifications((prev) => prev.filter((n) => n.job_id !== jobId));
      setNotificationCount((prev) => Math.max(0, prev - 1));
    } catch {
      // Silently fail
    }
  };

  return (
    <header className="flex h-16 items-center justify-between border-b border-slate-200 bg-white px-6">
      <div className="flex items-center gap-4">
        <Button variant="ghost" size="icon" className="lg:hidden">
          <Menu className="h-5 w-5" />
        </Button>
        <h1 className="text-lg font-semibold text-slate-900 lg:text-xl">
          Admin Dashboard
        </h1>
      </div>
      <div className="flex items-center gap-4">
        {/* Report Notifications */}
        <DropdownMenu>
          <DropdownMenuTrigger asChild>
            <Button variant="ghost" size="icon" className="relative">
              <Bell className="h-5 w-5" />
              {notificationCount > 0 && (
                <span className="absolute -top-1 -right-1 flex h-5 w-5 items-center justify-center rounded-full bg-red-500 text-xs font-medium text-white">
                  {notificationCount > 9 ? '9+' : notificationCount}
                </span>
              )}
            </Button>
          </DropdownMenuTrigger>
          <DropdownMenuContent align="end" className="w-80">
            <DropdownMenuLabel>Report Notifications</DropdownMenuLabel>
            <DropdownMenuSeparator />
            {notifications.length === 0 ? (
              <div className="px-2 py-4 text-center text-sm text-slate-500">
                No new notifications
              </div>
            ) : (
              notifications.slice(0, 5).map((notification) => (
                <DropdownMenuItem
                  key={notification.job_id}
                  className="flex items-start gap-3 p-3"
                  onClick={() => markAsSeen(notification.job_id)}
                >
                  <FileText className="h-5 w-5 text-blue-500 flex-shrink-0 mt-0.5" />
                  <div className="flex-1 min-w-0">
                    <p className="text-sm font-medium text-slate-900">
                      {notification.schedule_name || 'Report Ready'}
                    </p>
                    <p className="text-xs text-slate-500 truncate">
                      {notification.report_type.replace('_', ' ')} report completed
                    </p>
                    <p className="text-xs text-slate-400">
                      {new Date(notification.completed_at).toLocaleString()}
                    </p>
                  </div>
                </DropdownMenuItem>
              ))
            )}
            {notifications.length > 0 && (
              <>
                <DropdownMenuSeparator />
                <DropdownMenuItem asChild>
                  <Link href="/dashboard/reports/history" className="w-full text-center text-sm text-blue-600">
                    View all reports
                  </Link>
                </DropdownMenuItem>
              </>
            )}
          </DropdownMenuContent>
        </DropdownMenu>

        <DropdownMenu>
          <DropdownMenuTrigger asChild>
            <Button variant="ghost" className="flex items-center gap-2">
              <User className="h-5 w-5" />
              <span className="hidden text-sm font-medium md:inline-block">
                {user?.name || 'Admin'}
              </span>
            </Button>
          </DropdownMenuTrigger>
          <DropdownMenuContent align="end" className="w-56">
            <DropdownMenuLabel>
              <div className="flex flex-col space-y-1">
                <p className="text-sm font-medium">{user?.name}</p>
                <p className="text-xs text-slate-500">{user?.email}</p>
                <p className="text-xs text-slate-400 capitalize">{user?.role}</p>
              </div>
            </DropdownMenuLabel>
            <DropdownMenuSeparator />
            <DropdownMenuItem
              onClick={() => logout()}
              className="text-red-600 focus:text-red-600"
            >
              <LogOut className="mr-2 h-4 w-4" />
              Sign out
            </DropdownMenuItem>
          </DropdownMenuContent>
        </DropdownMenu>
      </div>
    </header>
  );
}
