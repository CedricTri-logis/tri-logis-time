import { createServerClient } from '@supabase/ssr';
import { NextResponse, type NextRequest } from 'next/server';

// Cache role checks per user for 5 minutes to avoid repeated DB queries
const roleCache = new Map<string, { role: string; ts: number }>();
const ROLE_CACHE_TTL = 5 * 60 * 1000;

export async function middleware(request: NextRequest) {
  const response = NextResponse.next({ request });

  const isProtected = request.nextUrl.pathname.startsWith('/dashboard');
  const isLoginPage = request.nextUrl.pathname === '/login';

  // Skip Supabase calls entirely for non-protected, non-login routes
  if (!isProtected && !isLoginPage) {
    return response;
  }

  const supabase = createServerClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL!.trim(),
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!.trim(),
    {
      cookies: {
        getAll: () => request.cookies.getAll(),
        setAll: (cookiesToSet) => {
          cookiesToSet.forEach(({ name, value, options }) => {
            request.cookies.set(name, value);
            response.cookies.set(name, value, options);
          });
        },
      },
    }
  );

  // Use getSession (local JWT decode) instead of getUser (network call to Supabase)
  // This is safe for routing decisions — actual data access is protected by RLS
  const { data: { session } } = await supabase.auth.getSession();
  const user = session?.user ?? null;

  // Redirect to login if accessing protected route without auth
  if (isProtected && !user) {
    return NextResponse.redirect(new URL('/login', request.url));
  }

  // Redirect to dashboard if already authenticated and on login page
  if (isLoginPage && user) {
    const hasErrorParam = request.nextUrl.searchParams.has('error');
    if (!hasErrorParam) {
      return NextResponse.redirect(new URL('/dashboard', request.url));
    }
    // User is logged in but has an error param (e.g. unauthorized) — sign them out so they can re-login
    await supabase.auth.signOut();
    const loginResponse = NextResponse.redirect(new URL('/login', request.url));
    response.cookies.getAll().forEach((cookie) => {
      if (cookie.name.startsWith('sb-')) {
        loginResponse.cookies.delete(cookie.name);
      }
    });
    return loginResponse;
  }

  // Check role for dashboard access (cached)
  if (isProtected && user) {
    const cached = roleCache.get(user.id);
    let userRole: string | undefined;

    if (cached && Date.now() - cached.ts < ROLE_CACHE_TTL) {
      userRole = cached.role;
    } else {
      const { data: profile } = await supabase
        .from('employee_profiles')
        .select('role')
        .eq('id', user.id)
        .single();

      userRole = profile?.role;
      if (userRole) {
        roleCache.set(user.id, { role: userRole, ts: Date.now() });
      }
    }

    if (!userRole || !['admin', 'super_admin'].includes(userRole)) {
      return NextResponse.redirect(new URL('/login?error=unauthorized', request.url));
    }
  }

  return response;
}

export const config = {
  // Only run middleware on page navigations, not on static assets, images, or API routes
  matcher: ['/dashboard/:path*', '/login'],
};
