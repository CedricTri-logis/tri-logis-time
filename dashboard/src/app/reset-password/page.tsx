'use client';

import { useState, useEffect } from 'react';
import { useUpdatePassword } from '@refinedev/core';
import { useRouter } from 'next/navigation';
import { Button } from '@/components/ui/button';
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card';
import { supabaseClient } from '@/lib/supabase/client';

export default function ResetPasswordPage() {
  const [password, setPassword] = useState('');
  const [confirmPassword, setConfirmPassword] = useState('');
  const [error, setError] = useState('');
  const [success, setSuccess] = useState(false);
  const [ready, setReady] = useState(false);
  const { mutate: updatePassword, isPending } = useUpdatePassword();
  const router = useRouter();

  useEffect(() => {
    // Check if session already exists (PKCE flow: code exchanged server-side in /auth/callback)
    supabaseClient.auth.getSession().then(({ data: { session } }) => {
      if (session) {
        setReady(true);
      }
    });

    // Also listen for PASSWORD_RECOVERY event (implicit flow fallback)
    const { data: { subscription } } = supabaseClient.auth.onAuthStateChange((event) => {
      if (event === 'PASSWORD_RECOVERY') {
        setReady(true);
      }
    });

    return () => subscription.unsubscribe();
  }, []);

  const handleSubmit = (e: React.FormEvent) => {
    e.preventDefault();
    setError('');

    if (password.length < 6) {
      setError('Le mot de passe doit contenir au moins 6 caractères.');
      return;
    }

    if (password !== confirmPassword) {
      setError('Les mots de passe ne correspondent pas.');
      return;
    }

    updatePassword({ password }, {
      onSuccess: () => {
        setSuccess(true);
      },
      onError: (err: unknown) => {
        const message = err instanceof Error ? err.message : 'Échec de la mise à jour du mot de passe.';
        setError(message);
      },
    });
  };

  return (
    <div className="min-h-screen flex items-center justify-center bg-slate-50 p-4">
      <Card className="w-full max-w-md">
        <CardHeader className="space-y-1">
          <CardTitle className="text-2xl font-bold text-center">Définir un nouveau mot de passe</CardTitle>
          <CardDescription className="text-center">
            Entrez votre nouveau mot de passe ci-dessous
          </CardDescription>
        </CardHeader>
        <CardContent>
          {success ? (
            <div className="space-y-4">
              <div className="p-3 bg-green-50 border border-green-200 rounded-md text-sm text-green-700">
                Votre mot de passe a été mis à jour avec succès.
              </div>
              <a
                href="ca.trilogis.gpstracker://login"
                className="block w-full text-center bg-slate-900 text-white py-2 px-4 rounded-md text-sm font-medium hover:bg-slate-800 transition-colors"
              >
                Ouvrir l'application Tri-Logis Time
              </a>
              <div className="text-center">
                <a
                  href="/login"
                  className="text-sm text-slate-500 hover:text-slate-700 underline-offset-4 hover:underline"
                >
                  Ou se connecter sur le web
                </a>
              </div>
            </div>
          ) : (
            <>
              {error && (
                <div className="mb-4 p-3 bg-red-50 border border-red-200 rounded-md text-sm text-red-600">
                  {error}
                </div>
              )}
              <form onSubmit={handleSubmit} className="space-y-4">
                <div className="space-y-2">
                  <label htmlFor="password" className="text-sm font-medium text-slate-700">
                    Nouveau mot de passe
                  </label>
                  <input
                    id="password"
                    name="new-password"
                    type="password"
                    autoComplete="new-password"
                    value={password}
                    onChange={(e) => setPassword(e.target.value)}
                    placeholder="Entrez le nouveau mot de passe"
                    required
                    minLength={6}
                    className="w-full px-3 py-2 border border-slate-300 rounded-md text-sm focus:outline-none focus:ring-2 focus:ring-slate-400 focus:border-transparent"
                  />
                </div>
                <div className="space-y-2">
                  <label htmlFor="confirmPassword" className="text-sm font-medium text-slate-700">
                    Confirmer le mot de passe
                  </label>
                  <input
                    id="confirmPassword"
                    name="confirm-password"
                    type="password"
                    autoComplete="new-password"
                    value={confirmPassword}
                    onChange={(e) => setConfirmPassword(e.target.value)}
                    placeholder="Confirmez le nouveau mot de passe"
                    required
                    minLength={6}
                    className="w-full px-3 py-2 border border-slate-300 rounded-md text-sm focus:outline-none focus:ring-2 focus:ring-slate-400 focus:border-transparent"
                  />
                </div>
                <Button
                  type="submit"
                  className="w-full"
                  disabled={isPending}
                >
                  {isPending ? 'Mise à jour...' : 'Mettre à jour'}
                </Button>
              </form>
            </>
          )}
        </CardContent>
      </Card>
    </div>
  );
}
