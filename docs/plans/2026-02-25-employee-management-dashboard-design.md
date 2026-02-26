# Employee Management Dashboard — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add phone editing, email editing, and employee creation to the dashboard employee management page.

**Architecture:** One Supabase migration adds the phone update RPC and modifies `get_employee_detail` to return `phone_number`. Two Next.js API routes handle email update and employee creation (both require Supabase Admin Client with `service_role` key). Dashboard UI gets phone/email fields in the existing form and a new "Add Employee" dialog.

**Tech Stack:** Next.js 14+ API Routes, Supabase Admin Client (`@supabase/supabase-js`), shadcn/ui, Zod, React Hook Form

---

### Task 1: Supabase Migration — `admin_update_phone_number` RPC + `get_employee_detail` phone field

**Files:**
- Create: `supabase/migrations/042_admin_phone_and_detail_update.sql`

**Step 1: Write the migration**

```sql
-- =============================================================================
-- Migration 042: Admin phone update RPC + phone_number in get_employee_detail
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. RPC: admin_update_phone_number
-- Updates phone in both employee_profiles and auth.users
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION admin_update_phone_number(
    p_user_id UUID,
    p_phone TEXT DEFAULT NULL
)
RETURNS JSONB AS $$
DECLARE
    v_caller_role TEXT;
    v_target_role TEXT;
BEGIN
    -- Get caller's role
    SELECT ep.role INTO v_caller_role
    FROM employee_profiles ep
    WHERE ep.id = (SELECT auth.uid());

    -- Only admin/super_admin
    IF v_caller_role NOT IN ('admin', 'super_admin') THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', jsonb_build_object('code', 'ACCESS_DENIED', 'message', 'Only admins can update phone numbers')
        );
    END IF;

    -- Get target's role
    SELECT ep.role INTO v_target_role
    FROM employee_profiles ep
    WHERE ep.id = p_user_id;

    IF v_target_role IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', jsonb_build_object('code', 'NOT_FOUND', 'message', 'Employee not found')
        );
    END IF;

    -- Super admin protection
    IF v_target_role = 'super_admin' AND v_caller_role != 'super_admin' THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', jsonb_build_object('code', 'PROTECTED_USER', 'message', 'Cannot modify super admin')
        );
    END IF;

    -- Validate phone format if not null
    IF p_phone IS NOT NULL AND p_phone !~ '^\+1[2-9]\d{9}$' THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', jsonb_build_object('code', 'INVALID_FORMAT', 'message', 'Phone must be E.164 Canadian format: +1XXXXXXXXXX')
        );
    END IF;

    -- Check uniqueness if not null
    IF p_phone IS NOT NULL AND EXISTS (
        SELECT 1 FROM employee_profiles WHERE phone_number = p_phone AND id != p_user_id
    ) THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', jsonb_build_object('code', 'DUPLICATE_PHONE', 'message', 'This phone number is already assigned to another employee')
        );
    END IF;

    -- Update employee_profiles
    UPDATE employee_profiles
    SET phone_number = p_phone
    WHERE id = p_user_id;

    -- Update auth.users
    UPDATE auth.users
    SET phone = p_phone
    WHERE id = p_user_id;

    RETURN jsonb_build_object('success', true);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION admin_update_phone_number IS 'Admin-only: update employee phone number in both tables';

-- -----------------------------------------------------------------------------
-- 2. Update get_employee_detail to include phone_number
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION get_employee_detail(p_employee_id UUID)
RETURNS TABLE (
    id UUID,
    email TEXT,
    full_name TEXT,
    employee_id TEXT,
    phone_number TEXT,
    role TEXT,
    status TEXT,
    privacy_consent_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ,
    updated_at TIMESTAMPTZ,
    current_supervisor JSONB,
    supervision_history JSONB,
    has_active_shift BOOLEAN
) AS $$
DECLARE
    v_caller_role TEXT;
BEGIN
    -- Get caller's role
    SELECT ep.role INTO v_caller_role
    FROM employee_profiles ep
    WHERE ep.id = (SELECT auth.uid());

    -- Only admin/super_admin can access
    IF v_caller_role NOT IN ('admin', 'super_admin') THEN
        RAISE EXCEPTION 'Access denied';
    END IF;

    RETURN QUERY
    SELECT
        ep.id,
        ep.email,
        ep.full_name,
        ep.employee_id,
        ep.phone_number,
        ep.role,
        ep.status,
        ep.privacy_consent_at,
        ep.created_at,
        ep.updated_at,
        -- Current supervisor
        (
            SELECT jsonb_build_object(
                'id', mgr.id,
                'full_name', mgr.full_name,
                'email', mgr.email
            )
            FROM employee_supervisors es
            JOIN employee_profiles mgr ON mgr.id = es.manager_id
            WHERE es.employee_id = ep.id
            AND (es.effective_to IS NULL OR es.effective_to >= CURRENT_DATE)
            ORDER BY es.effective_from DESC
            LIMIT 1
        ) as current_supervisor,
        -- Supervision history
        COALESCE(
            (
                SELECT jsonb_agg(
                    jsonb_build_object(
                        'id', es.id,
                        'manager_id', es.manager_id,
                        'manager_name', mgr.full_name,
                        'manager_email', mgr.email,
                        'supervision_type', es.supervision_type,
                        'effective_from', es.effective_from,
                        'effective_to', es.effective_to
                    ) ORDER BY es.effective_from DESC
                )
                FROM employee_supervisors es
                JOIN employee_profiles mgr ON mgr.id = es.manager_id
                WHERE es.employee_id = ep.id
            ),
            '[]'::JSONB
        ) as supervision_history,
        -- Has active shift
        EXISTS (
            SELECT 1 FROM shifts s
            WHERE s.employee_id = ep.id AND s.status = 'active'
        ) as has_active_shift
    FROM employee_profiles ep
    WHERE ep.id = p_employee_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION get_employee_detail IS 'Get employee details with supervision history (admin only)';
```

**Step 2: Apply migration**

Run: `cd supabase && supabase db push`
Expected: Migration applied successfully

**Step 3: Commit**

```bash
git add supabase/migrations/042_admin_phone_and_detail_update.sql
git commit -m "feat(db): add admin_update_phone_number RPC and phone_number to get_employee_detail"
```

---

### Task 2: Supabase Admin Client Setup for Dashboard

**Files:**
- Create: `dashboard/src/lib/supabase/admin.ts`
- Modify: `dashboard/.env.local`

**Step 1: Add `SUPABASE_SERVICE_ROLE_KEY` to `.env.local`**

Add this line (get the key from Supabase dashboard → Settings → API → service_role key):

```
SUPABASE_SERVICE_ROLE_KEY=<your-service-role-key>
```

**Step 2: Create admin client helper**

```typescript
// dashboard/src/lib/supabase/admin.ts
import { createClient } from '@supabase/supabase-js';

/**
 * Server-side only Supabase admin client using service_role key.
 * NEVER import this in client components.
 */
export function createAdminClient() {
  const supabaseUrl = process.env.NEXT_PUBLIC_SUPABASE_URL!.trim();
  const serviceRoleKey = process.env.SUPABASE_SERVICE_ROLE_KEY!.trim();

  if (!serviceRoleKey) {
    throw new Error('SUPABASE_SERVICE_ROLE_KEY is not set');
  }

  return createClient(supabaseUrl, serviceRoleKey, {
    auth: {
      autoRefreshToken: false,
      persistSession: false,
    },
  });
}
```

**Step 3: Commit**

```bash
git add dashboard/src/lib/supabase/admin.ts
git commit -m "feat(dashboard): add server-side Supabase admin client"
```

---

### Task 3: Auth Helper for API Routes

**Files:**
- Create: `dashboard/src/lib/supabase/server.ts`

**Step 1: Create server-side auth helper**

This verifies the caller's JWT and checks they're admin/super_admin:

```typescript
// dashboard/src/lib/supabase/server.ts
import { createClient } from '@supabase/supabase-js';
import { NextRequest } from 'next/server';

/**
 * Verify the request's auth token and check admin role.
 * Returns the user ID and role, or null if unauthorized.
 */
export async function verifyAdmin(request: NextRequest): Promise<{
  userId: string;
  role: string;
} | null> {
  const authHeader = request.headers.get('authorization');
  if (!authHeader?.startsWith('Bearer ')) {
    return null;
  }

  const token = authHeader.slice(7);
  const supabase = createClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL!.trim(),
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!.trim()
  );

  const { data: { user }, error } = await supabase.auth.getUser(token);
  if (error || !user) {
    return null;
  }

  // Check role in employee_profiles using admin client
  const { createAdminClient } = await import('./admin');
  const adminClient = createAdminClient();
  const { data: profile } = await adminClient
    .from('employee_profiles')
    .select('role')
    .eq('id', user.id)
    .single();

  if (!profile || !['admin', 'super_admin'].includes(profile.role)) {
    return null;
  }

  return { userId: user.id, role: profile.role };
}
```

**Step 2: Commit**

```bash
git add dashboard/src/lib/supabase/server.ts
git commit -m "feat(dashboard): add server-side auth verification helper for API routes"
```

---

### Task 4: API Route — Update Email

**Files:**
- Create: `dashboard/src/app/api/employees/update-email/route.ts`

**Step 1: Create the API route**

```typescript
// dashboard/src/app/api/employees/update-email/route.ts
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
```

**Step 2: Commit**

```bash
git add dashboard/src/app/api/employees/update-email/route.ts
git commit -m "feat(dashboard): add API route for admin email update"
```

---

### Task 5: API Route — Create Employee (Invitation)

**Files:**
- Create: `dashboard/src/app/api/employees/create/route.ts`

**Step 1: Create the API route**

```typescript
// dashboard/src/app/api/employees/create/route.ts
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
```

**Step 2: Commit**

```bash
git add dashboard/src/app/api/employees/create/route.ts
git commit -m "feat(dashboard): add API route for employee creation via invitation"
```

---

### Task 6: Update Types and Validation Schemas

**Files:**
- Modify: `dashboard/src/types/employee.ts`
- Modify: `dashboard/src/lib/validations/employee.ts`

**Step 1: Add `phone_number` to `EmployeeDetail` type**

In `dashboard/src/types/employee.ts`, add `phone_number` to `EmployeeDetail`:

```typescript
// Add to EmployeeProfile interface (after employee_id):
phone_number: string | null;
```

And add new types:

```typescript
// Request/response for phone update
export interface UpdatePhoneParams {
  p_user_id: string;
  p_phone: string | null;
}

// Request for email update (API route)
export interface UpdateEmailRequest {
  employee_id: string;
  email: string;
}

// Request for employee creation (API route)
export interface CreateEmployeeRequest {
  email: string;
  full_name?: string;
  role?: EmployeeRoleType;
  supervisor_id?: string;
}

// Generic API response
export interface ApiResponse {
  success: boolean;
  error?: string;
  employee_id?: string;
}
```

**Step 2: Add validation schemas**

In `dashboard/src/lib/validations/employee.ts`, add:

```typescript
// Phone number schema (E.164 Canadian)
export const phoneSchema = z
  .string()
  .regex(/^\(\d{3}\) \d{3}-\d{4}$/, 'Format: (XXX) XXX-XXXX')
  .or(z.literal(''))
  .optional();

// Schema for editing employee profile (extended with phone and email)
export const employeeEditExtendedSchema = z.object({
  full_name: z
    .string()
    .max(100, 'Name must be 100 characters or less')
    .nullable()
    .optional(),
  employee_id: z
    .string()
    .max(50, 'Employee ID must be 50 characters or less')
    .regex(/^[a-zA-Z0-9-]*$/, 'Only letters, numbers, and dashes allowed')
    .nullable()
    .optional(),
  phone_number: z
    .string()
    .max(20)
    .nullable()
    .optional(),
  email: z
    .string()
    .email('Invalid email address')
    .max(255)
    .optional(),
});

export type EmployeeEditExtendedInput = z.infer<typeof employeeEditExtendedSchema>;

// Schema for creating an employee
export const createEmployeeSchema = z.object({
  email: z.string().email('Invalid email address').max(255),
  full_name: z.string().max(100).optional(),
  role: z.enum(['employee', 'manager', 'admin', 'super_admin']).default('employee'),
  supervisor_id: z.string().uuid().optional(),
});

export type CreateEmployeeInput = z.infer<typeof createEmployeeSchema>;
```

**Step 3: Commit**

```bash
git add dashboard/src/types/employee.ts dashboard/src/lib/validations/employee.ts
git commit -m "feat(dashboard): add types and validation schemas for phone, email, and employee creation"
```

---

### Task 7: Update Employee Form — Add Phone and Email Fields

**Files:**
- Modify: `dashboard/src/components/dashboard/employees/employee-form.tsx`

**Step 1: Update the form component**

Replace the entire file with the extended version that includes phone and email fields:

```typescript
'use client';

import { useForm } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import { AlertTriangle } from 'lucide-react';
import {
  Form,
  FormControl,
  FormDescription,
  FormField,
  FormItem,
  FormLabel,
  FormMessage,
} from '@/components/ui/form';
import { Input } from '@/components/ui/input';
import { Button } from '@/components/ui/button';
import { employeeEditExtendedSchema, type EmployeeEditExtendedInput } from '@/lib/validations/employee';

interface EmployeeFormProps {
  defaultValues: EmployeeEditExtendedInput;
  onSubmit: (data: EmployeeEditExtendedInput) => Promise<void>;
  isSubmitting?: boolean;
  isDisabled?: boolean;
  showEmailWarning?: boolean;
}

/**
 * Format phone for display: +18195551234 → (819) 555-1234
 */
function formatPhoneDisplay(phone: string | null | undefined): string {
  if (!phone) return '';
  const digits = phone.replace(/\D/g, '');
  // Remove leading 1 for Canadian numbers
  const local = digits.startsWith('1') ? digits.slice(1) : digits;
  if (local.length === 10) {
    return `(${local.slice(0, 3)}) ${local.slice(3, 6)}-${local.slice(6)}`;
  }
  return phone;
}

/**
 * Parse display phone to E.164: (819) 555-1234 → +18195551234
 */
export function parsePhoneToE164(display: string): string | null {
  if (!display.trim()) return null;
  const digits = display.replace(/\D/g, '');
  const local = digits.startsWith('1') ? digits.slice(1) : digits;
  if (local.length === 10) {
    return `+1${local}`;
  }
  return null;
}

export function EmployeeForm({
  defaultValues,
  onSubmit,
  isSubmitting = false,
  isDisabled = false,
  showEmailWarning = false,
}: EmployeeFormProps) {
  const form = useForm<EmployeeEditExtendedInput>({
    resolver: zodResolver(employeeEditExtendedSchema),
    defaultValues: {
      ...defaultValues,
      phone_number: formatPhoneDisplay(defaultValues.phone_number),
    },
  });

  const handleSubmit = form.handleSubmit(async (data) => {
    await onSubmit(data);
  });

  return (
    <Form {...form}>
      <form onSubmit={handleSubmit} className="space-y-6">
        <FormField
          control={form.control}
          name="full_name"
          render={({ field }) => (
            <FormItem>
              <FormLabel>Full Name</FormLabel>
              <FormControl>
                <Input
                  placeholder="Enter full name"
                  {...field}
                  value={field.value ?? ''}
                  disabled={isDisabled}
                />
              </FormControl>
              <FormDescription>
                The display name shown throughout the system.
              </FormDescription>
              <FormMessage />
            </FormItem>
          )}
        />

        <FormField
          control={form.control}
          name="employee_id"
          render={({ field }) => (
            <FormItem>
              <FormLabel>Employee ID</FormLabel>
              <FormControl>
                <Input
                  placeholder="Enter employee ID"
                  {...field}
                  value={field.value ?? ''}
                  disabled={isDisabled}
                />
              </FormControl>
              <FormDescription>
                A unique identifier (letters, numbers, and dashes only).
              </FormDescription>
              <FormMessage />
            </FormItem>
          )}
        />

        <FormField
          control={form.control}
          name="email"
          render={({ field }) => (
            <FormItem>
              <FormLabel>Email</FormLabel>
              <FormControl>
                <Input
                  type="email"
                  placeholder="employee@example.com"
                  {...field}
                  value={field.value ?? ''}
                  disabled={isDisabled}
                />
              </FormControl>
              {showEmailWarning && (
                <div className="flex items-center gap-2 rounded-md bg-amber-50 p-2 text-xs text-amber-800">
                  <AlertTriangle className="h-3 w-3 flex-shrink-0" />
                  Changing the email will change this employee&apos;s login credentials.
                </div>
              )}
              <FormMessage />
            </FormItem>
          )}
        />

        <FormField
          control={form.control}
          name="phone_number"
          render={({ field }) => (
            <FormItem>
              <FormLabel>Phone Number</FormLabel>
              <FormControl>
                <Input
                  type="tel"
                  placeholder="(XXX) XXX-XXXX"
                  {...field}
                  value={field.value ?? ''}
                  disabled={isDisabled}
                />
              </FormControl>
              <FormDescription>
                Canadian format. Used for SMS authentication.
              </FormDescription>
              <FormMessage />
            </FormItem>
          )}
        />

        {!isDisabled && (
          <div className="flex justify-end">
            <Button type="submit" disabled={isSubmitting}>
              {isSubmitting ? 'Saving...' : 'Save Changes'}
            </Button>
          </div>
        )}
      </form>
    </Form>
  );
}
```

**Step 2: Commit**

```bash
git add dashboard/src/components/dashboard/employees/employee-form.tsx
git commit -m "feat(dashboard): add phone and email fields to employee form"
```

---

### Task 8: Update Employee Detail Page — Handle Phone and Email Saves

**Files:**
- Modify: `dashboard/src/app/dashboard/employees/[id]/page.tsx`

**Step 1: Update the detail page**

Key changes to `[id]/page.tsx`:
1. Import `EmployeeEditExtendedInput` instead of `EmployeeEditInput`
2. Import `parsePhoneToE164` from employee-form
3. Update `handleProfileUpdate` to handle phone and email separately
4. Pass `phone_number` and `email` as defaultValues to `EmployeeForm`
5. Add `showEmailWarning` prop

The `handleProfileUpdate` function becomes:

```typescript
const handleProfileUpdate = useCallback(
  async (formData: EmployeeEditExtendedInput) => {
    setIsSubmitting(true);
    try {
      // 1. Update name and employee_id via existing RPC
      const { data: result, error } = await supabaseClient.rpc('update_employee_profile', {
        p_employee_id: employeeId,
        p_full_name: formData.full_name,
        p_employee_id_value: formData.employee_id,
      });

      if (error) throw error;
      const response = result as UpdateEmployeeResponse;
      if (!response.success) {
        toast.error(response.error?.message || 'Failed to update profile');
        return;
      }

      // 2. Update phone if changed
      const newPhone = parsePhoneToE164(formData.phone_number ?? '');
      if (newPhone !== employee?.phone_number && (newPhone || employee?.phone_number)) {
        const { data: phoneResult, error: phoneError } = await supabaseClient.rpc('admin_update_phone_number', {
          p_user_id: employeeId,
          p_phone: newPhone,
        });
        if (phoneError) throw phoneError;
        const phoneResponse = phoneResult as { success: boolean; error?: { message: string } };
        if (!phoneResponse.success) {
          toast.error(phoneResponse.error?.message || 'Failed to update phone');
          return;
        }
      }

      // 3. Update email if changed
      if (formData.email && formData.email !== employee?.email) {
        const token = (await supabaseClient.auth.getSession()).data.session?.access_token;
        const res = await fetch('/api/employees/update-email', {
          method: 'POST',
          headers: {
            'Content-Type': 'application/json',
            'Authorization': `Bearer ${token}`,
          },
          body: JSON.stringify({
            employee_id: employeeId,
            email: formData.email,
          }),
        });
        const emailResult = await res.json();
        if (!emailResult.success) {
          toast.error(emailResult.error || 'Failed to update email');
          return;
        }
      }

      toast.success('Profile updated successfully');
      refetch();
    } catch (err) {
      console.error('Update error:', err);
      toast.error('Failed to update profile');
    } finally {
      setIsSubmitting(false);
    }
  },
  [employeeId, employee?.phone_number, employee?.email, refetch]
);
```

Update the `EmployeeForm` usage to pass new defaultValues and props:

```tsx
<EmployeeForm
  defaultValues={{
    full_name: employee.full_name,
    employee_id: employee.employee_id,
    email: employee.email,
    phone_number: employee.phone_number,
  }}
  onSubmit={handleProfileUpdate}
  isSubmitting={isSubmitting}
  isDisabled={!canEdit}
  showEmailWarning={true}
/>
```

**Step 2: Commit**

```bash
git add dashboard/src/app/dashboard/employees/\[id\]/page.tsx
git commit -m "feat(dashboard): handle phone and email updates in employee detail page"
```

---

### Task 9: Create Employee Dialog + Button

**Files:**
- Create: `dashboard/src/components/dashboard/employees/create-employee-dialog.tsx`
- Modify: `dashboard/src/app/dashboard/employees/page.tsx`

**Step 1: Create the dialog component**

```typescript
// dashboard/src/components/dashboard/employees/create-employee-dialog.tsx
'use client';

import { useState } from 'react';
import { useForm } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import { toast } from 'sonner';
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogHeader,
  DialogTitle,
} from '@/components/ui/dialog';
import {
  Form,
  FormControl,
  FormDescription,
  FormField,
  FormItem,
  FormLabel,
  FormMessage,
} from '@/components/ui/form';
import { Input } from '@/components/ui/input';
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from '@/components/ui/select';
import { Button } from '@/components/ui/button';
import { createEmployeeSchema, type CreateEmployeeInput } from '@/lib/validations/employee';
import { supabaseClient } from '@/lib/supabase/client';
import type { ManagerListItem } from '@/types/employee';

interface CreateEmployeeDialogProps {
  isOpen: boolean;
  onClose: () => void;
  onCreated: () => void;
}

export function CreateEmployeeDialog({ isOpen, onClose, onCreated }: CreateEmployeeDialogProps) {
  const [isSubmitting, setIsSubmitting] = useState(false);
  const [managers, setManagers] = useState<ManagerListItem[]>([]);
  const [managersLoaded, setManagersLoaded] = useState(false);

  const form = useForm<CreateEmployeeInput>({
    resolver: zodResolver(createEmployeeSchema),
    defaultValues: {
      email: '',
      full_name: '',
      role: 'employee',
    },
  });

  // Load managers when dialog opens
  const loadManagers = async () => {
    if (managersLoaded) return;
    const { data } = await supabaseClient.rpc('get_managers_list');
    if (data) {
      setManagers(data as ManagerListItem[]);
      setManagersLoaded(true);
    }
  };

  const handleOpenChange = (open: boolean) => {
    if (open) {
      loadManagers();
    } else {
      onClose();
      form.reset();
    }
  };

  const handleSubmit = form.handleSubmit(async (data) => {
    setIsSubmitting(true);
    try {
      const token = (await supabaseClient.auth.getSession()).data.session?.access_token;
      const res = await fetch('/api/employees/create', {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'Authorization': `Bearer ${token}`,
        },
        body: JSON.stringify(data),
      });

      const result = await res.json();
      if (!result.success) {
        toast.error(result.error || 'Failed to create employee');
        return;
      }

      toast.success('Invitation sent! The employee will receive an email to set up their account.');
      form.reset();
      onCreated();
      onClose();
    } catch (err) {
      console.error('Create employee error:', err);
      toast.error('Failed to create employee');
    } finally {
      setIsSubmitting(false);
    }
  });

  return (
    <Dialog open={isOpen} onOpenChange={handleOpenChange}>
      <DialogContent className="sm:max-w-[425px]">
        <DialogHeader>
          <DialogTitle>Add Employee</DialogTitle>
          <DialogDescription>
            Send an invitation email. The employee will create their password when they click the link.
          </DialogDescription>
        </DialogHeader>

        <Form {...form}>
          <form onSubmit={handleSubmit} className="space-y-4">
            <FormField
              control={form.control}
              name="email"
              render={({ field }) => (
                <FormItem>
                  <FormLabel>Email *</FormLabel>
                  <FormControl>
                    <Input type="email" placeholder="employee@example.com" {...field} />
                  </FormControl>
                  <FormDescription>
                    An invitation will be sent to this address.
                  </FormDescription>
                  <FormMessage />
                </FormItem>
              )}
            />

            <FormField
              control={form.control}
              name="full_name"
              render={({ field }) => (
                <FormItem>
                  <FormLabel>Full Name</FormLabel>
                  <FormControl>
                    <Input placeholder="John Doe" {...field} />
                  </FormControl>
                  <FormMessage />
                </FormItem>
              )}
            />

            <FormField
              control={form.control}
              name="role"
              render={({ field }) => (
                <FormItem>
                  <FormLabel>Role</FormLabel>
                  <Select onValueChange={field.onChange} defaultValue={field.value}>
                    <FormControl>
                      <SelectTrigger>
                        <SelectValue />
                      </SelectTrigger>
                    </FormControl>
                    <SelectContent>
                      <SelectItem value="employee">Employee</SelectItem>
                      <SelectItem value="manager">Manager</SelectItem>
                      <SelectItem value="admin">Admin</SelectItem>
                    </SelectContent>
                  </Select>
                  <FormMessage />
                </FormItem>
              )}
            />

            <FormField
              control={form.control}
              name="supervisor_id"
              render={({ field }) => (
                <FormItem>
                  <FormLabel>Supervisor</FormLabel>
                  <Select onValueChange={field.onChange} value={field.value ?? ''}>
                    <FormControl>
                      <SelectTrigger>
                        <SelectValue placeholder="None" />
                      </SelectTrigger>
                    </FormControl>
                    <SelectContent>
                      {managers.map((mgr) => (
                        <SelectItem key={mgr.id} value={mgr.id}>
                          {mgr.full_name || mgr.email}
                        </SelectItem>
                      ))}
                    </SelectContent>
                  </Select>
                  <FormMessage />
                </FormItem>
              )}
            />

            <div className="flex justify-end gap-2 pt-4">
              <Button type="button" variant="outline" onClick={onClose}>
                Cancel
              </Button>
              <Button type="submit" disabled={isSubmitting}>
                {isSubmitting ? 'Sending...' : 'Send Invitation'}
              </Button>
            </div>
          </form>
        </Form>
      </DialogContent>
    </Dialog>
  );
}
```

**Step 2: Add "Add Employee" button to employees list page**

In `dashboard/src/app/dashboard/employees/page.tsx`, add:
- Import `CreateEmployeeDialog` and `UserPlus` icon
- Add `showCreateDialog` state
- Add button next to the page title
- Add dialog component

The page header becomes:

```tsx
<div className="flex items-center justify-between">
  <div className="flex items-center gap-3">
    <div className="rounded-lg bg-slate-100 p-2">
      <Users className="h-6 w-6 text-slate-600" />
    </div>
    <div>
      <h1 className="text-2xl font-semibold text-slate-900">Employees</h1>
      <p className="text-sm text-slate-500">
        {isLoading ? 'Loading...' : `${totalCount} employee${totalCount !== 1 ? 's' : ''}`}
      </p>
    </div>
  </div>
  <Button onClick={() => setShowCreateDialog(true)}>
    <UserPlus className="mr-2 h-4 w-4" />
    Add Employee
  </Button>
</div>

{/* At the end of the component, before closing </div>: */}
<CreateEmployeeDialog
  isOpen={showCreateDialog}
  onClose={() => setShowCreateDialog(false)}
  onCreated={() => query.refetch()}
/>
```

**Step 3: Commit**

```bash
git add dashboard/src/components/dashboard/employees/create-employee-dialog.tsx dashboard/src/app/dashboard/employees/page.tsx
git commit -m "feat(dashboard): add employee creation dialog with invitation flow"
```

---

### Task 10: Update Memory + Final Verification

**Step 1: Update MEMORY.md**

Add to migration numbering:
```
- 042: admin_update_phone (admin_update_phone_number RPC, phone_number added to get_employee_detail)
```

**Step 2: Manual verification checklist**

1. Open `https://time.trilogis.ca/dashboard/employees`
2. Click on an employee → verify phone and email fields appear
3. Edit phone number → save → verify both tables updated
4. Edit email → save → verify login works with new email
5. Click "Add Employee" → fill form → verify invitation email received
6. Click invitation link → verify account creation works
7. Login with new account → verify PhoneRegistrationScreen appears

**Step 3: Commit all remaining changes**

```bash
git commit -m "feat: complete employee management — phone/email editing + employee creation"
```
