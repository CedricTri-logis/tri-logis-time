import type { AuthProvider } from '@refinedev/core';
import { supabaseClient } from '@/lib/supabase/client';

export const authProvider: AuthProvider = {
  login: async ({ email, password }) => {
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

  onError: async (error) => {
    console.error('Auth error:', error);
    return { error };
  },
};
