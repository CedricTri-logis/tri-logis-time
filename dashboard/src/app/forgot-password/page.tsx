'use client';

import { useState } from 'react';
import { useForgotPassword } from '@refinedev/core';
import Link from 'next/link';
import { Button } from '@/components/ui/button';
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card';

export default function ForgotPasswordPage() {
  const [email, setEmail] = useState('');
  const [sent, setSent] = useState(false);
  const { mutate: forgotPassword, isPending } = useForgotPassword<{ email: string }>();

  const handleSubmit = (e: React.FormEvent) => {
    e.preventDefault();
    forgotPassword({ email }, {
      onSuccess: () => setSent(true),
    });
  };

  return (
    <div className="min-h-screen flex items-center justify-center bg-slate-50 p-4">
      <Card className="w-full max-w-md">
        <CardHeader className="space-y-1">
          <CardTitle className="text-2xl font-bold text-center">Reset Password</CardTitle>
          <CardDescription className="text-center">
            {sent
              ? 'Check your email for the reset link'
              : 'Enter your email to receive a password reset link'}
          </CardDescription>
        </CardHeader>
        <CardContent>
          {sent ? (
            <div className="space-y-4">
              <div className="p-3 bg-green-50 border border-green-200 rounded-md text-sm text-green-700">
                A password reset link has been sent to <strong>{email}</strong>. Check your inbox.
              </div>
              <div className="text-center">
                <Link
                  href="/login"
                  className="text-sm text-slate-500 hover:text-slate-700 underline-offset-4 hover:underline"
                >
                  Back to sign in
                </Link>
              </div>
            </div>
          ) : (
            <form onSubmit={handleSubmit} className="space-y-4">
              <div className="space-y-2">
                <label htmlFor="email" className="text-sm font-medium text-slate-700">
                  Email
                </label>
                <input
                  id="email"
                  name="email"
                  type="email"
                  autoComplete="email"
                  value={email}
                  onChange={(e) => setEmail(e.target.value)}
                  placeholder="admin@company.com"
                  required
                  className="w-full px-3 py-2 border border-slate-300 rounded-md text-sm focus:outline-none focus:ring-2 focus:ring-slate-400 focus:border-transparent"
                />
              </div>
              <Button
                type="submit"
                className="w-full"
                disabled={isPending}
              >
                {isPending ? 'Sending...' : 'Send Reset Link'}
              </Button>
              <div className="text-center">
                <Link
                  href="/login"
                  className="text-sm text-slate-500 hover:text-slate-700 underline-offset-4 hover:underline"
                >
                  Back to sign in
                </Link>
              </div>
            </form>
          )}
        </CardContent>
      </Card>
    </div>
  );
}
