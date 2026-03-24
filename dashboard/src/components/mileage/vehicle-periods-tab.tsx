'use client';

import { useState, useEffect, useCallback, useMemo } from 'react';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Button } from '@/components/ui/button';
import { Badge } from '@/components/ui/badge';
import { Checkbox } from '@/components/ui/checkbox';
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from '@/components/ui/dialog';
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from '@/components/ui/table';
import { Input } from '@/components/ui/input';
import { Textarea } from '@/components/ui/textarea';
import { Label } from '@/components/ui/label';
import { Car, Building2, Loader2, RefreshCw, Pencil } from 'lucide-react';
import { toast } from 'sonner';
import { supabaseClient } from '@/lib/supabase/client';
import { toLocalDateString } from '@/lib/utils/date-utils';
import type { EmployeeVehiclePeriod } from '@/types/mileage';

interface Employee {
  id: string;
  full_name: string | null;
  email: string | null;
}

interface EmployeeRow {
  employee_id: string;
  employee_name: string;
  personal: EmployeeVehiclePeriod | null;
  company: EmployeeVehiclePeriod | null;
}

function formatDate(dateStr: string): string {
  const d = new Date(dateStr + 'T00:00:00');
  return d.toLocaleDateString('fr-CA', { month: 'short', day: 'numeric', year: 'numeric' });
}

export function VehiclePeriodsTab() {
  const [periods, setPeriods] = useState<EmployeeVehiclePeriod[]>([]);
  const [employees, setEmployees] = useState<Employee[]>([]);
  const [isLoading, setIsLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const [showDialog, setShowDialog] = useState(false);
  const [editingEmployee, setEditingEmployee] = useState<EmployeeRow | null>(null);
  const [formPersonal, setFormPersonal] = useState(false);
  const [formCompany, setFormCompany] = useState(false);
  const [formPersonalSince, setFormPersonalSince] = useState('');
  const [formCompanySince, setFormCompanySince] = useState('');
  const [formNotes, setFormNotes] = useState('');
  const [isSaving, setIsSaving] = useState(false);

  useEffect(() => {
    (async () => {
      const { data } = await supabaseClient
        .from('employee_profiles')
        .select('id, full_name, email')
        .order('full_name');
      if (data) setEmployees(data as Employee[]);
    })();
  }, []);

  const fetchPeriods = useCallback(async () => {
    setIsLoading(true);
    setError(null);
    try {
      const { data, error: fetchError } = await supabaseClient
        .from('employee_vehicle_periods')
        .select('*')
        .order('started_at', { ascending: false });
      if (fetchError) { setError(fetchError.message); return; }
      setPeriods((data ?? []) as EmployeeVehiclePeriod[]);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Erreur lors du chargement');
    } finally {
      setIsLoading(false);
    }
  }, []);

  useEffect(() => { fetchPeriods(); }, [fetchPeriods]);

  const employeeRows = useMemo((): EmployeeRow[] => {
    const today = toLocalDateString(new Date());
    const personalMap = new Map<string, EmployeeVehiclePeriod>();
    const companyMap = new Map<string, EmployeeVehiclePeriod>();
    for (const p of periods) {
      const isActive = !p.ended_at || p.ended_at >= today;
      if (!isActive) continue;
      if (p.vehicle_type === 'personal' && !personalMap.has(p.employee_id)) personalMap.set(p.employee_id, p);
      if (p.vehicle_type === 'company' && !companyMap.has(p.employee_id)) companyMap.set(p.employee_id, p);
    }
    return employees.map((emp) => ({
      employee_id: emp.id,
      employee_name: emp.full_name || emp.email || 'Inconnu',
      personal: personalMap.get(emp.id) ?? null,
      company: companyMap.get(emp.id) ?? null,
    })).sort((a, b) => a.employee_name.localeCompare(b.employee_name));
  }, [periods, employees]);

  const stats = useMemo(() => ({
    total: employees.length,
    withPersonal: employeeRows.filter(r => r.personal).length,
    withCompany: employeeRows.filter(r => r.company).length,
  }), [employees, employeeRows]);

  const openEditDialog = useCallback((row: EmployeeRow) => {
    setEditingEmployee(row);
    setFormPersonal(!!row.personal);
    setFormCompany(!!row.company);
    setFormPersonalSince(row.personal?.started_at?.split('T')[0] || toLocalDateString(new Date()));
    setFormCompanySince(row.company?.started_at?.split('T')[0] || toLocalDateString(new Date()));
    setFormNotes('');
    setShowDialog(true);
  }, []);

  const handleSave = useCallback(async () => {
    if (!editingEmployee) return;
    setIsSaving(true);
    const empId = editingEmployee.employee_id;
    const today = toLocalDateString(new Date());
    try {
      if (formPersonal && !editingEmployee.personal) {
        const { error } = await supabaseClient.from('employee_vehicle_periods')
          .insert({ employee_id: empId, vehicle_type: 'personal', started_at: formPersonalSince, notes: formNotes.trim() || null });
        if (error) { toast.error(error.message.includes('overlap') ? 'Chevauchement de période personnel.' : error.message); setIsSaving(false); return; }
      } else if (!formPersonal && editingEmployee.personal) {
        const { error } = await supabaseClient.from('employee_vehicle_periods').update({ ended_at: today }).eq('id', editingEmployee.personal.id);
        if (error) { toast.error(error.message); setIsSaving(false); return; }
      }
      if (formCompany && !editingEmployee.company) {
        const { error } = await supabaseClient.from('employee_vehicle_periods')
          .insert({ employee_id: empId, vehicle_type: 'company', started_at: formCompanySince, notes: formNotes.trim() || null });
        if (error) { toast.error(error.message.includes('overlap') ? 'Chevauchement de période compagnie.' : error.message); setIsSaving(false); return; }
      } else if (!formCompany && editingEmployee.company) {
        const { error } = await supabaseClient.from('employee_vehicle_periods').update({ ended_at: today }).eq('id', editingEmployee.company.id);
        if (error) { toast.error(error.message); setIsSaving(false); return; }
      }
      toast.success('Véhicules mis à jour.');
      setShowDialog(false);
      fetchPeriods();
    } catch (err) {
      toast.error(err instanceof Error ? err.message : 'Erreur inattendue');
    } finally {
      setIsSaving(false);
    }
  }, [editingEmployee, formPersonal, formCompany, formPersonalSince, formCompanySince, formNotes, fetchPeriods]);

  return (
    <div className="space-y-6">
      <div className="grid grid-cols-3 gap-4">
        <Card>
          <CardContent className="pt-4 pb-3 text-center">
            <p className="text-2xl font-bold">{stats.total}</p>
            <p className="text-xs text-muted-foreground">Employés</p>
          </CardContent>
        </Card>
        <Card>
          <CardContent className="pt-4 pb-3 text-center">
            <div className="flex items-center justify-center gap-1.5 mb-0.5">
              <Car className="h-4 w-4 text-blue-600" />
              <p className="text-2xl font-bold text-blue-600">{stats.withPersonal}</p>
            </div>
            <p className="text-xs text-muted-foreground">Véhicule personnel</p>
          </CardContent>
        </Card>
        <Card>
          <CardContent className="pt-4 pb-3 text-center">
            <div className="flex items-center justify-center gap-1.5 mb-0.5">
              <Building2 className="h-4 w-4 text-purple-600" />
              <p className="text-2xl font-bold text-purple-600">{stats.withCompany}</p>
            </div>
            <p className="text-xs text-muted-foreground">Véhicule compagnie</p>
          </CardContent>
        </Card>
      </div>

      <Card>
        <CardHeader>
          <div className="flex items-center justify-between">
            <CardTitle className="flex items-center gap-2">
              <Car className="h-5 w-5" />
              Véhicules par employé
            </CardTitle>
            <Button variant="ghost" size="sm" onClick={fetchPeriods} disabled={isLoading}>
              <RefreshCw className={`h-4 w-4 ${isLoading ? 'animate-spin' : ''}`} />
            </Button>
          </div>
        </CardHeader>
        <CardContent>
          {error && <div className="rounded-md bg-red-50 p-3 text-sm text-red-700 mb-4">{error}</div>}
          {isLoading ? (
            <div className="animate-pulse space-y-3">
              {Array.from({ length: 5 }).map((_, i) => (
                <div key={i} className="flex gap-4 py-3">
                  <div className="h-4 w-32 rounded bg-slate-200" />
                  <div className="h-4 w-24 rounded bg-slate-200" />
                  <div className="h-4 w-24 rounded bg-slate-200" />
                  <div className="h-4 w-16 rounded bg-slate-200" />
                </div>
              ))}
            </div>
          ) : (
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead>Employé</TableHead>
                  <TableHead className="text-center">
                    <div className="flex items-center justify-center gap-1"><Car className="h-3.5 w-3.5 text-blue-600" /> Personnel</div>
                  </TableHead>
                  <TableHead className="text-center">
                    <div className="flex items-center justify-center gap-1"><Building2 className="h-3.5 w-3.5 text-purple-600" /> Compagnie</div>
                  </TableHead>
                  <TableHead className="text-right">Actions</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {employeeRows.map((row) => (
                  <TableRow key={row.employee_id}>
                    <TableCell className="font-medium">{row.employee_name}</TableCell>
                    <TableCell className="text-center">
                      {row.personal ? (
                        <Badge className="bg-blue-100 text-blue-700 hover:bg-blue-100">Depuis {formatDate(row.personal.started_at)}</Badge>
                      ) : <span className="text-muted-foreground">&mdash;</span>}
                    </TableCell>
                    <TableCell className="text-center">
                      {row.company ? (
                        <Badge className="bg-purple-100 text-purple-700 hover:bg-purple-100">Depuis {formatDate(row.company.started_at)}</Badge>
                      ) : <span className="text-muted-foreground">&mdash;</span>}
                    </TableCell>
                    <TableCell className="text-right">
                      <Button variant="ghost" size="sm" onClick={() => openEditDialog(row)}><Pencil className="h-3.5 w-3.5" /></Button>
                    </TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          )}
        </CardContent>
      </Card>

      <Dialog open={showDialog} onOpenChange={setShowDialog}>
        <DialogContent className="sm:max-w-[420px]">
          <DialogHeader>
            <DialogTitle>Véhicules &mdash; {editingEmployee?.employee_name}</DialogTitle>
            <DialogDescription>Cochez les types de véhicule auxquels cet employé a accès.</DialogDescription>
          </DialogHeader>
          <div className="space-y-4 py-2">
            <div className="flex items-start gap-3 p-3 rounded-lg border">
              <Checkbox id="personal" checked={formPersonal} onCheckedChange={(checked) => setFormPersonal(!!checked)} />
              <div className="flex-1">
                <label htmlFor="personal" className="flex items-center gap-2 font-medium cursor-pointer">
                  <Car className="h-4 w-4 text-blue-600" /> Véhicule personnel
                </label>
                {formPersonal && !editingEmployee?.personal && (
                  <div className="mt-2">
                    <Label htmlFor="personal-since" className="text-xs text-muted-foreground">Depuis</Label>
                    <Input id="personal-since" type="date" value={formPersonalSince} onChange={(e) => setFormPersonalSince(e.target.value)} className="mt-1 h-8" />
                  </div>
                )}
                {editingEmployee?.personal && <p className="text-xs text-muted-foreground mt-1">Actif depuis {formatDate(editingEmployee.personal.started_at)}</p>}
              </div>
            </div>
            <div className="flex items-start gap-3 p-3 rounded-lg border">
              <Checkbox id="company" checked={formCompany} onCheckedChange={(checked) => setFormCompany(!!checked)} />
              <div className="flex-1">
                <label htmlFor="company" className="flex items-center gap-2 font-medium cursor-pointer">
                  <Building2 className="h-4 w-4 text-purple-600" /> Véhicule compagnie
                </label>
                {formCompany && !editingEmployee?.company && (
                  <div className="mt-2">
                    <Label htmlFor="company-since" className="text-xs text-muted-foreground">Depuis</Label>
                    <Input id="company-since" type="date" value={formCompanySince} onChange={(e) => setFormCompanySince(e.target.value)} className="mt-1 h-8" />
                  </div>
                )}
                {editingEmployee?.company && <p className="text-xs text-muted-foreground mt-1">Actif depuis {formatDate(editingEmployee.company.started_at)}</p>}
              </div>
            </div>
            {((formPersonal && !editingEmployee?.personal) || (formCompany && !editingEmployee?.company)) && (
              <div className="space-y-2">
                <Label htmlFor="notes">Notes (optionnel)</Label>
                <Textarea id="notes" value={formNotes} onChange={(e) => setFormNotes(e.target.value)} placeholder="Ex: Honda Civic 2022" rows={2} />
              </div>
            )}
          </div>
          <DialogFooter>
            <Button variant="outline" onClick={() => setShowDialog(false)} disabled={isSaving}>Annuler</Button>
            <Button onClick={handleSave} disabled={isSaving}>
              {isSaving ? <><Loader2 className="h-4 w-4 mr-2 animate-spin" />Enregistrement...</> : 'Enregistrer'}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </div>
  );
}
