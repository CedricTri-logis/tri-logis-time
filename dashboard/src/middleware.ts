import { createServerClient } from '@supabase/ssr';
import { NextResponse, type NextRequest } from 'next/server';

export async function middleware(request: NextRequest) {
  const response = NextResponse.next({ request });

  const supabase = createServerClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,
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

  // Refresh session if needed
  const { data: { user } } = await supabase.auth.getUser();

  const isProtected = request.nextUrl.pathname.startsWith('/dashboard');
  const isLoginPage = request.nextUrl.pathname === '/login';

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
    // Clear auth cookies from the response to prevent redirect loop
    const loginResponse = NextResponse.redirect(new URL('/login', request.url));
    response.cookies.getAll().forEach((cookie) => {
      if (cookie.name.startsWith('sb-')) {
        loginResponse.cookies.delete(cookie.name);
      }
    });
    return loginResponse;
  }

  // Check role for dashboard access
  if (isProtected && user) {
    const { data: profile } = await supabase
      .from('employee_profiles')
      .select('role')
      .eq('id', user.id)
      .single();

    const userRole = profile?.role;

    // Only admin and super_admin can access dashboard
    if (!userRole || !['admin', 'super_admin'].includes(userRole)) {
      return NextResponse.redirect(new URL('/login?error=unauthorized', request.url));
    }
  }

  return response;
}

export const config = {
  matcher: ['/((?!_next/static|_next/image|favicon.ico|.*\\..*).*)'],
};
