import { NextRequest, NextResponse } from 'next/server';
import { z } from 'zod';
import { verifyAdmin } from '@/lib/supabase/server';
import { createAdminClient } from '@/lib/supabase/admin';

const updateEmailSchema = z.object({
  employee_id: z.string().uuid(),
  email: z.string().email().max(255),
});

export async function POST(request: NextRequest) {
  try {
    // Verify admin
    const caller = await verifyAdmin(request);
    if (!caller) {
      return NextResponse.json(
        { success: false, error: 'Unauthorized' },
        { status: 401 }
      );
    }

    // Parse body
    const body = await request.json();
    const parseResult = updateEmailSchema.safeParse(body);
    if (!parseResult.success) {
      return NextResponse.json(
        { success: false, error: parseResult.error.issues[0].message },
        { status: 400 }
      );
    }

    const { employee_id, email } = parseResult.data;
    const adminClient = createAdminClient();

    // Check target exists and get role
    const { data: target } = await adminClient
      .from('employee_profiles')
      .select('role, email')
      .eq('id', employee_id)
      .single();

    if (!target) {
      return NextResponse.json(
        { success: false, error: 'Employee not found' },
        { status: 404 }
      );
    }

    // Super admin protection
    if (target.role === 'super_admin' && caller.role !== 'super_admin') {
      return NextResponse.json(
        { success: false, error: 'Cannot modify super admin' },
        { status: 403 }
      );
    }

    // Check uniqueness
    const { data: existing } = await adminClient
      .from('employee_profiles')
      .select('id')
      .eq('email', email)
      .neq('id', employee_id)
      .single();

    if (existing) {
      return NextResponse.json(
        { success: false, error: 'This email is already used by another employee' },
        { status: 409 }
      );
    }

    // Update auth.users email (immediate, no confirmation)
    const { error: authError } = await adminClient.auth.admin.updateUserById(
      employee_id,
      { email, email_confirm: true }
    );

    if (authError) {
      return NextResponse.json(
        { success: false, error: authError.message },
        { status: 500 }
      );
    }

    // Sync to employee_profiles (no trigger exists for this)
    const { error: profileError } = await adminClient
      .from('employee_profiles')
      .update({ email })
      .eq('id', employee_id);

    if (profileError) {
      return NextResponse.json(
        { success: false, error: profileError.message },
        { status: 500 }
      );
    }

    return NextResponse.json({ success: true });
  } catch (error) {
    console.error('Update email error:', error);
    return NextResponse.json(
      { success: false, error: 'Internal server error' },
      { status: 500 }
    );
  }
}
