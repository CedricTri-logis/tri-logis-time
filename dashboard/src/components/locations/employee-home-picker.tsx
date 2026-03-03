'use client';

import { useState, useEffect, useCallback } from 'react';
import { supabaseClient } from '@/lib/supabase/client';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { X, Plus, Loader2 } from 'lucide-react';
import { toast } from 'sonner';

interface EmployeeHomePickerProps {
  locationId: string;
  isEmployeeHome: boolean;
}

interface EmployeeRow {
  id: string;
  full_name: string;
}

export function EmployeeHomePicker({ locationId, isEmployeeHome }: EmployeeHomePickerProps) {
  const [employees, setEmployees] = useState<EmployeeRow[]>([]);
  const [searchResults, setSearchResults] = useState<EmployeeRow[]>([]);
  const [search, setSearch] = useState('');
  const [isLoading, setIsLoading] = useState(false);
  const [isSearching, setIsSearching] = useState(false);

  const fetchEmployees = useCallback(async () => {
    setIsLoading(true);
    const { data } = await supabaseClient
      .from('employee_home_locations')
      .select('employee_id')
      .eq('location_id', locationId);

    if (data && data.length > 0) {
      const ids = data.map((d) => d.employee_id);
      const { data: profiles } = await supabaseClient
        .from('employee_profiles')
        .select('id, full_name')
        .in('id', ids)
        .order('full_name');
      setEmployees(profiles ?? []);
    } else {
      setEmployees([]);
    }
    setIsLoading(false);
  }, [locationId]);

  useEffect(() => {
    if (isEmployeeHome) fetchEmployees();
  }, [isEmployeeHome, fetchEmployees]);

  const handleSearch = useCallback(async (query: string) => {
    setSearch(query);
    if (query.length < 2) { setSearchResults([]); return; }
    setIsSearching(true);
    const { data } = await supabaseClient
      .from('employee_profiles')
      .select('id, full_name')
      .ilike('full_name', `%${query}%`)
      .order('full_name')
      .limit(10);
    const existingIds = new Set(employees.map((e) => e.id));
    setSearchResults((data ?? []).filter((e) => !existingIds.has(e.id)));
    setIsSearching(false);
  }, [employees]);

  const handleAdd = useCallback(async (employeeId: string) => {
    const { error } = await supabaseClient
      .from('employee_home_locations')
      .insert({ employee_id: employeeId, location_id: locationId });
    if (error) { toast.error("Erreur lors de l'ajout"); return; }
    toast.success('Employé associé');
    setSearch('');
    setSearchResults([]);
    fetchEmployees();
  }, [locationId, fetchEmployees]);

  const handleRemove = useCallback(async (employeeId: string) => {
    const { error } = await supabaseClient
      .from('employee_home_locations')
      .delete()
      .eq('employee_id', employeeId)
      .eq('location_id', locationId);
    if (error) { toast.error('Erreur lors de la suppression'); return; }
    toast.success('Association supprimée');
    fetchEmployees();
  }, [locationId, fetchEmployees]);

  if (!isEmployeeHome) return null;

  return (
    <div className="space-y-3">
      <p className="text-sm font-medium">Employés associés à ce domicile</p>
      {isLoading ? (
        <Loader2 className="h-4 w-4 animate-spin" />
      ) : (
        <>
          {employees.map((emp) => (
            <div key={emp.id} className="flex items-center justify-between rounded-lg border p-2">
              <span className="text-sm">{emp.full_name}</span>
              <Button variant="ghost" size="icon" onClick={() => handleRemove(emp.id)}>
                <X className="h-4 w-4 text-red-500" />
              </Button>
            </div>
          ))}
          {employees.length === 0 && (
            <p className="text-sm text-slate-500">Aucun employé associé</p>
          )}
          <div className="relative">
            <Input
              placeholder="Rechercher un employé..."
              value={search}
              onChange={(e) => handleSearch(e.target.value)}
            />
            {isSearching && <Loader2 className="h-4 w-4 animate-spin absolute right-3 top-3" />}
            {searchResults.length > 0 && (
              <div className="absolute z-10 w-full mt-1 bg-white border rounded-md shadow-lg max-h-48 overflow-y-auto">
                {searchResults.map((emp) => (
                  <button
                    key={emp.id}
                    className="w-full text-left px-3 py-2 hover:bg-slate-50 text-sm flex items-center gap-2"
                    onClick={() => handleAdd(emp.id)}
                  >
                    <Plus className="h-3 w-3" />
                    {emp.full_name}
                  </button>
                ))}
              </div>
            )}
          </div>
        </>
      )}
    </div>
  );
}
