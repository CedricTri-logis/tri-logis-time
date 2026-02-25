'use client';

import { useEffect } from 'react';
import { useRouter, useSearchParams } from 'next/navigation';
import { supabaseClient } from '@/lib/supabase/client';

export default function AuthCallbackPage() {
  const router = useRouter();
  const searchParams = useSearchParams();

  useEffect(() => {
    const code = searchParams.get('code');
    const next = searchParams.get('next') ?? '/reset-password';

    if (code) {
      supabaseClient.auth.exchangeCodeForSession(code).then(({ error }) => {
        if (error) {
          console.error('Code exchange failed:', error.message);
          router.replace('/login?error=invalid_reset_link');
        } else {
          router.replace(next);
        }
      });
    } else {
      router.replace('/login');
    }
  }, [router, searchParams]);

  return (
    <div className="min-h-screen flex items-center justify-center bg-slate-50">
      <div className="text-center">
        <div className="animate-spin rounded-full h-8 w-8 border-b-2 border-slate-900 mx-auto mb-4" />
        <p className="text-sm text-slate-500">Redirecting...</p>
      </div>
    </div>
  );
}
