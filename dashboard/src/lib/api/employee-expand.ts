import { supabaseClient } from '@/lib/supabase/client';

export interface EmployeeExpandCategory {
  category: 'renovation' | 'entretien' | 'menage' | 'admin';
  started_at: string;
  ended_at: string | null;
}

export interface EmployeeExpandRate {
  rate: number;
  effective_from: string;
  effective_to: string | null;
}

export interface EmployeeExpandDetails {
  categories: EmployeeExpandCategory[];
  rates: EmployeeExpandRate[];
}

export async function getEmployeeExpandDetails(
  employeeId: string
): Promise<EmployeeExpandDetails> {
  const { data, error } = await supabaseClient.rpc('get_employee_expand_details', {
    p_employee_id: employeeId,
  });

  if (error) throw error;
  return data as EmployeeExpandDetails;
}
