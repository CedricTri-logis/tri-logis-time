'use client';

import { Suspense } from 'react';
import { Refine } from '@refinedev/core';
import routerProvider from '@refinedev/nextjs-router';
import { dataProvider } from '@/lib/providers/data-provider';
import { authProvider } from '@/lib/providers/auth-provider';

function RefineProvider({ children }: { children: React.ReactNode }) {
  return (
    <Refine
      dataProvider={dataProvider}
      authProvider={authProvider}
      routerProvider={routerProvider}
      resources={[
        {
          name: 'dashboard',
          list: '/dashboard',
        },
        {
          name: 'teams',
          list: '/dashboard/teams',
        },
      ]}
      options={{
        syncWithLocation: true,
        warnWhenUnsavedChanges: true,
        disableTelemetry: true,
      }}
    >
      {children}
    </Refine>
  );
}

export function Providers({ children }: { children: React.ReactNode }) {
  return (
    <Suspense fallback={<div className="min-h-screen flex items-center justify-center">Loading...</div>}>
      <RefineProvider>{children}</RefineProvider>
    </Suspense>
  );
}
