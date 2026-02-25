import { NextRequest, NextResponse } from 'next/server';
import { z } from 'zod';
import { verifyAdmin } from '@/lib/supabase/server';
import { createAdminClient } from '@/lib/supabase/admin';

const createEmployeeSchema = z.object({
  email: z.string().email().max(255),
  full_name: z.string().max(100).optional(),
  role: z.enum(['employee', 'manager', 'admin', 'super_admin']).default('employee'),
  supervisor_id: z.string().uuid().optional(),
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
    const parseResult = createEmployeeSchema.safeParse(body);
    if (!parseResult.success) {
      return NextResponse.json(
        { success: false, error: parseResult.error.issues[0].message },
        { status: 400 }
      );
    }

    const { email, full_name, role, supervisor_id } = parseResult.data;
    const adminClient = createAdminClient();

    // Only super_admin can create super_admin
    if (role === 'super_admin' && caller.role !== 'super_admin') {
      return NextResponse.json(
        { success: false, error: 'Only super admins can create super admin accounts' },
        { status: 403 }
      );
    }

    // Check email not already used
    const { data: existing } = await adminClient
      .from('employee_profiles')
      .select('id')
      .eq('email', email)
      .single();

    if (existing) {
      return NextResponse.json(
        { success: false, error: 'An employee with this email already exists' },
        { status: 409 }
      );
    }

    // Create user via invitation (sends magic link email)
    const { data: inviteData, error: inviteError } = await adminClient.auth.admin.inviteUserByEmail(
      email,
      {
        data: {
          full_name: full_name || null,
        },
      }
    );

    if (inviteError) {
      return NextResponse.json(
        { success: false, error: inviteError.message },
        { status: 500 }
      );
    }

    const newUserId = inviteData.user.id;

    // Update full_name in employee_profiles (trigger handle_new_user creates the row)
    if (full_name) {
      await adminClient
        .from('employee_profiles')
        .update({ full_name })
        .eq('id', newUserId);
    }

    // Set role if not default 'employee'
    if (role !== 'employee') {
      await adminClient
        .from('employee_profiles')
        .update({ role })
        .eq('id', newUserId);
    }

    // Assign supervisor if specified
    if (supervisor_id) {
      await adminClient.rpc('assign_supervisor', {
        p_employee_id: newUserId,
        p_manager_id: supervisor_id,
        p_supervision_type: 'direct',
      });
    }

    return NextResponse.json({
      success: true,
      employee_id: newUserId,
    });
  } catch (error) {
    console.error('Create employee error:', error);
    return NextResponse.json(
      { success: false, error: 'Internal server error' },
      { status: 500 }
    );
  }
}
