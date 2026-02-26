import type { AuthProvider } from '@refinedev/core';
import { supabaseClient } from '@/lib/supabase/client';

export const authProvider: AuthProvider = {
  login: async ({ email, password }) => {
    // Clear any stale session before attempting fresh login
    await supabaseClient.auth.signOut();

    const { data, error } = await supabaseClient.auth.signInWithPassword({
      email,
      password,
    });

    if (error) {
      return {
        success: false,
        error: {
          name: 'LoginError',
          message: error.message,
        },
      };
    }

    if (data?.session) {
      return {
        success: true,
        redirectTo: '/dashboard',
      };
    }

    return {
      success: false,
      error: {
        name: 'LoginError',
        message: 'Invalid credentials',
      },
    };
  },

  logout: async () => {
    const { error } = await supabaseClient.auth.signOut();

    if (error) {
      return {
        success: false,
        error: {
          name: 'LogoutError',
          message: error.message,
        },
      };
    }

    return {
      success: true,
      redirectTo: '/login',
    };
  },

  check: async () => {
    const { data: { user }, error } = await supabaseClient.auth.getUser();

    if (error || !user) {
      return {
        authenticated: false,
        error: error ? { name: 'AuthError', message: error.message } : undefined,
        redirectTo: '/login',
      };
    }

    return {
      authenticated: true,
    };
  },

  getPermissions: async () => {
    const { data: { user } } = await supabaseClient.auth.getUser();

    if (!user) {
      return null;
    }

    // Get user role from employee_profiles
    const { data: profile } = await supabaseClient
      .from('employee_profiles')
      .select('role')
      .eq('id', user.id)
      .single();

    return profile?.role ?? 'employee';
  },

  getIdentity: async () => {
    const { data: { user } } = await supabaseClient.auth.getUser();

    if (!user) {
      return null;
    }

    // Get user details from employee_profiles
    const { data: profile } = await supabaseClient
      .from('employee_profiles')
      .select('id, email, full_name, role')
      .eq('id', user.id)
      .single();

    if (!profile) {
      return {
        id: user.id,
        email: user.email,
        name: user.email,
        role: 'employee',
      };
    }

    return {
      id: profile.id,
      email: profile.email,
      name: profile.full_name || profile.email,
      role: profile.role,
    };
  },

  forgotPassword: async ({ email }) => {
    const { error } = await supabaseClient.auth.resetPasswordForEmail(email, {
      redirectTo: `${window.location.origin}/auth/callback?next=/reset-password`,
    });

    if (error) {
      return {
        success: false,
        error: {
          name: 'ForgotPasswordError',
          message: error.message,
        },
      };
    }

    return {
      success: true,
      successNotification: {
        message: 'Password reset email sent',
        description: 'Check your inbox for the reset link.',
      },
    };
  },

  updatePassword: async ({ password }) => {
    const { error } = await supabaseClient.auth.updateUser({ password });

    if (error) {
      return {
        success: false,
        error: {
          name: 'UpdatePasswordError',
          message: error.message,
        },
      };
    }

    return {
      success: true,
      redirectTo: '/dashboard',
    };
  },

  onError: async (error) => {
    // Only log meaningful auth errors (skip empty objects from silent RPC failures)
    const status = (error as any)?.statusCode ?? (error as any)?.status;
    if (status === 401 || status === 403) {
      console.error('Auth error:', error);
      return { logout: true, redirectTo: '/login', error };
    }
    return {};
  },
};
