'use client';

import { useState, useEffect, useCallback, useMemo } from 'react';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Button } from '@/components/ui/button';
import { Badge } from '@/components/ui/badge';
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from '@/components/ui/dialog';
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from '@/components/ui/select';
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
import { Plus, Pencil, DollarSign, Loader2, RefreshCw, CalendarOff } from 'lucide-react';
import { toast } from 'sonner';
import { supabaseClient } from '@/lib/supabase/client';
import { toLocalDateString } from '@/lib/utils/date-utils';
import type { EmployeeMileageAllowance } from '@/types/mileage';

interface Employee {
  id: string;
  full_name: string | null;
  email: string | null;
}

type StatusFilter = 'all' | 'active' | 'expired';

function formatDate(dateStr: string): string {
  const d = new Date(dateStr);
  return d.toLocaleDateString('fr-CA', { month: 'short', day: 'numeric', year: 'numeric' });
}

function formatAmount(amount: number): string {
  return amount.toLocaleString('fr-CA', { style: 'currency', currency: 'CAD' });
}

type AllowanceWithEmployee = EmployeeMileageAllowance & {
  employee?: { id: string; name: string };
};

export function MileageAllowancesTab() {
  // Data state
  const [allowances, setAllowances] = useState<AllowanceWithEmployee[]>([]);
  const [employees, setEmployees] = useState<Employee[]>([]);
  const [isLoading, setIsLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  // Filter state
  const [statusFilter, setStatusFilter] = useState<StatusFilter>('all');

  // Add/Edit dialog state
  const [showDialog, setShowDialog] = useState(false);
  const [editingAllowance, setEditingAllowance] = useState<AllowanceWithEmployee | null>(null);
  const [isSaving, setIsSaving] = useState(false);

  // Form state
  const [formEmployeeId, setFormEmployeeId] = useState('');
  const [formAmount, setFormAmount] = useState('');
  const [formStartedAt, setFormStartedAt] = useState('');
  const [formEndedAt, setFormEndedAt] = useState('');
  const [formNotes, setFormNotes] = useState('');

  // End allowance dialog state
  const [endingAllowance, setEndingAllowance] = useState<AllowanceWithEmployee | null>(null);
  const [endDate, setEndDate] = useState('');
  const [isEnding, setIsEnding] = useState(false);

  // Fetch all employee profiles (for dropdown)
  useEffect(() => {
    (async () => {
      const { data } = await supabaseClient
        .from('employee_profiles')
        .select('id, full_name, email')
        .order('full_name');
      if (data) {
        setEmployees(data as Employee[]);
      }
    })();
  }, []);

  // Fetch allowances — uses two separate queries to avoid PostgREST recursive RLS
  const fetchAllowances = useCallback(async () => {
    setIsLoading(true);
    setError(null);
    try {
      // 1. Fetch mileage allowances
      const { data: allowancesData, error: allowancesError } = await supabaseClient
        .from('employee_mileage_allowances')
        .select('*')
        .order('started_at', { ascending: false });

      if (allowancesError) {
        setError(allowancesError.message);
        return;
      }

      if (!allowancesData || allowancesData.length === 0) {
        setAllowances([]);
        return;
      }

      // 2. Fetch employee profiles for all unique employee_ids
      const employeeIds = [...new Set(allowancesData.map((a) => a.employee_id).filter(Boolean))];
      const employeeMap: Record<string, { id: string; name: string }> = {};

      if (employeeIds.length > 0) {
        const { data: emps } = await supabaseClient
          .from('employee_profiles')
          .select('id, full_name, email')
          .in('id', employeeIds);

        if (emps) {
          for (const emp of emps) {
            employeeMap[emp.id] = {
              id: emp.id,
              name: emp.full_name || emp.email || 'Inconnu',
            };
          }
        }
      }

      // 3. Merge employee data into allowances
      const merged = allowancesData.map((allowance: any) => ({
        ...allowance,
        employee: employeeMap[allowance.employee_id] ?? { id: allowance.employee_id, name: 'Inconnu' },
      }));

      setAllowances(merged as AllowanceWithEmployee[]);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Erreur lors du chargement');
    } finally {
      setIsLoading(false);
    }
  }, []);

  useEffect(() => {
    fetchAllowances();
  }, [fetchAllowances]);

  // Summary stats
  const stats = useMemo(() => {
    const today = toLocalDateString(new Date());
    const total = allowances.length;
    const active = allowances.filter((a) => !a.ended_at || a.ended_at >= today).length;
    const expired = allowances.filter((a) => !!a.ended_at && a.ended_at < today).length;
    return { total, active, expired };
  }, [allowances]);

  // Filter allowances
  const filteredAllowances = useMemo(() => {
    const today = toLocalDateString(new Date());
    if (statusFilter === 'active') {
      return allowances.filter((a) => !a.ended_at || a.ended_at >= today);
    } else if (statusFilter === 'expired') {
      return allowances.filter((a) => !!a.ended_at && a.ended_at < today);
    }
    return allowances;
  }, [allowances, statusFilter]);

  // Open add dialog
  const openAddDialog = useCallback(() => {
    setEditingAllowance(null);
    setFormEmployeeId('');
    setFormAmount('');
    setFormStartedAt(toLocalDateString(new Date()));
    setFormEndedAt('');
    setFormNotes('');
    setShowDialog(true);
  }, []);

  // Open edit dialog
  const openEditDialog = useCallback((allowance: AllowanceWithEmployee) => {
    setEditingAllowance(allowance);
    setFormEmployeeId(allowance.employee_id);
    setFormAmount(String(allowance.amount_per_period));
    setFormStartedAt(allowance.started_at.split('T')[0]);
    setFormEndedAt(allowance.ended_at ? allowance.ended_at.split('T')[0] : '');
    setFormNotes(allowance.notes || '');
    setShowDialog(true);
  }, []);

  // Save (insert or update)
  const handleSave = useCallback(async () => {
    if (!formEmployeeId) {
      toast.error('Veuillez sélectionner un employé.');
      return;
    }
    if (!formAmount || isNaN(Number(formAmount)) || Number(formAmount) <= 0) {
      toast.error('Veuillez entrer un montant valide.');
      return;
    }
    if (!formStartedAt) {
      toast.error('Veuillez sélectionner une date de début.');
      return;
    }

    setIsSaving(true);
    try {
      const payload: any = {
        employee_id: formEmployeeId,
        amount_per_period: Number(formAmount),
        started_at: formStartedAt,
        ended_at: formEndedAt || null,
        notes: formNotes.trim() || null,
      };

      if (editingAllowance) {
        // Update
        const { error: updateError } = await supabaseClient
          .from('employee_mileage_allowances')
          .update(payload)
          .eq('id', editingAllowance.id);

        if (updateError) {
          toast.error(`Erreur: ${updateError.message}`);
          return;
        }
        toast.success('Forfait mis à jour avec succès.');
      } else {
        // Insert
        const { error: insertError } = await supabaseClient
          .from('employee_mileage_allowances')
          .insert(payload);

        if (insertError) {
          toast.error(`Erreur: ${insertError.message}`);
          return;
        }
        toast.success('Forfait ajouté avec succès.');
      }

      setShowDialog(false);
      fetchAllowances();
    } catch (err) {
      toast.error(err instanceof Error ? err.message : 'Erreur inattendue');
    } finally {
      setIsSaving(false);
    }
  }, [editingAllowance, formEmployeeId, formAmount, formStartedAt, formEndedAt, formNotes, fetchAllowances]);

  // Open end dialog
  const openEndDialog = useCallback((allowance: AllowanceWithEmployee) => {
    setEndingAllowance(allowance);
    setEndDate(toLocalDateString(new Date()));
  }, []);

  // End allowance (set ended_at)
  const handleEndAllowance = useCallback(async () => {
    if (!endingAllowance) return;
    if (!endDate) {
      toast.error('Veuillez sélectionner une date de fin.');
      return;
    }

    setIsEnding(true);
    try {
      const { error: updateError } = await supabaseClient
        .from('employee_mileage_allowances')
        .update({ ended_at: endDate })
        .eq('id', endingAllowance.id);

      if (updateError) {
        toast.error(`Erreur: ${updateError.message}`);
        return;
      }

      toast.success('Forfait terminé avec succès.');
      setEndingAllowance(null);
      fetchAllowances();
    } catch (err) {
      toast.error(err instanceof Error ? err.message : 'Erreur inattendue');
    } finally {
      setIsEnding(false);
    }
  }, [endingAllowance, endDate, fetchAllowances]);

  const getEmployeeName = (emp: Employee) => emp.full_name || emp.email || 'Inconnu';

  return (
    <div className="space-y-6">
      {/* Stats cards */}
      <div className="grid grid-cols-3 gap-4">
        <Card
          className={`cursor-pointer hover:ring-2 hover:ring-primary/20 ${statusFilter === 'all' ? 'ring-2 ring-primary' : ''}`}
          onClick={() => setStatusFilter('all')}
        >
          <CardContent className="pt-4 pb-3 text-center">
            <p className="text-2xl font-bold">{stats.total}</p>
            <p className="text-xs text-muted-foreground">Tous les forfaits</p>
          </CardContent>
        </Card>
        <Card
          className={`cursor-pointer hover:ring-2 hover:ring-green-500/20 ${statusFilter === 'active' ? 'ring-2 ring-green-500' : ''}`}
          onClick={() => setStatusFilter('active')}
        >
          <CardContent className="pt-4 pb-3 text-center">
            <p className="text-2xl font-bold text-green-600">{stats.active}</p>
            <p className="text-xs text-muted-foreground">Actifs</p>
          </CardContent>
        </Card>
        <Card
          className={`cursor-pointer hover:ring-2 hover:ring-gray-500/20 ${statusFilter === 'expired' ? 'ring-2 ring-gray-500' : ''}`}
          onClick={() => setStatusFilter('expired')}
        >
          <CardContent className="pt-4 pb-3 text-center">
            <p className="text-2xl font-bold text-muted-foreground">{stats.expired}</p>
            <p className="text-xs text-muted-foreground">Expirés</p>
          </CardContent>
        </Card>
      </div>

      {/* Main table card */}
      <Card>
        <CardHeader>
          <div className="flex items-center justify-between">
            <CardTitle className="flex items-center gap-2">
              <DollarSign className="h-5 w-5" />
              Forfaits kilométrage
              {statusFilter !== 'all' && (
                <Badge variant="secondary" className="ml-2 text-xs">
                  {statusFilter === 'active' ? 'Actif' : 'Expiré'} ({filteredAllowances.length})
                  <button
                    onClick={(e) => { e.stopPropagation(); setStatusFilter('all'); }}
                    className="ml-1 hover:text-destructive"
                  >
                    &times;
                  </button>
                </Badge>
              )}
            </CardTitle>
            <div className="flex items-center gap-2">
              {/* Active/Expired toggle */}
              <div className="flex items-center rounded-md border">
                <button
                  className={`px-3 py-1.5 text-xs font-medium rounded-l-md transition-colors ${
                    statusFilter === 'all' ? 'bg-primary text-primary-foreground' : 'hover:bg-muted'
                  }`}
                  onClick={() => setStatusFilter('all')}
                >
                  Tous ({stats.total})
                </button>
                <button
                  className={`px-3 py-1.5 text-xs font-medium border-l transition-colors ${
                    statusFilter === 'active' ? 'bg-primary text-primary-foreground' : 'hover:bg-muted'
                  }`}
                  onClick={() => setStatusFilter('active')}
                >
                  Actif ({stats.active})
                </button>
                <button
                  className={`px-3 py-1.5 text-xs font-medium rounded-r-md border-l transition-colors ${
                    statusFilter === 'expired' ? 'bg-primary text-primary-foreground' : 'hover:bg-muted'
                  }`}
                  onClick={() => setStatusFilter('expired')}
                >
                  Expiré ({stats.expired})
                </button>
              </div>

              <Button
                variant="ghost"
                size="sm"
                onClick={fetchAllowances}
                disabled={isLoading}
              >
                <RefreshCw className={`h-4 w-4 ${isLoading ? 'animate-spin' : ''}`} />
              </Button>

              <Button size="sm" onClick={openAddDialog}>
                <Plus className="h-4 w-4 mr-1" />
                Ajouter un forfait
              </Button>
            </div>
          </div>
        </CardHeader>
        <CardContent>
          {error && (
            <div className="rounded-md bg-red-50 p-3 text-sm text-red-700 mb-4">
              {error}
            </div>
          )}

          {isLoading ? (
            <div className="animate-pulse space-y-3">
              {Array.from({ length: 5 }).map((_, i) => (
                <div key={i} className="flex gap-4 py-3">
                  <div className="h-4 w-28 rounded bg-slate-200" />
                  <div className="h-4 w-20 rounded bg-slate-200" />
                  <div className="h-4 w-24 rounded bg-slate-200" />
                  <div className="h-4 w-24 rounded bg-slate-200" />
                  <div className="h-4 w-32 rounded bg-slate-200" />
                  <div className="h-4 w-16 rounded bg-slate-200" />
                </div>
              ))}
            </div>
          ) : filteredAllowances.length === 0 ? (
            <div className="py-8 text-center text-sm text-muted-foreground">
              {allowances.length === 0
                ? 'Aucun forfait kilométrage trouvé.'
                : 'Aucun forfait ne correspond aux filtres sélectionnés.'}
            </div>
          ) : (
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead>Employé</TableHead>
                  <TableHead>Montant / période</TableHead>
                  <TableHead>Début</TableHead>
                  <TableHead>Fin</TableHead>
                  <TableHead>Notes</TableHead>
                  <TableHead className="text-right">Actions</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {filteredAllowances.map((allowance) => {
                  const today = toLocalDateString(new Date());
                  const isActive = !allowance.ended_at || allowance.ended_at >= today;
                  return (
                    <TableRow key={allowance.id}>
                      <TableCell className="font-medium">
                        {allowance.employee?.name || 'Inconnu'}
                      </TableCell>
                      <TableCell>
                        <Badge className="bg-green-100 text-green-700 hover:bg-green-100 font-mono">
                          {formatAmount(allowance.amount_per_period)}
                        </Badge>
                      </TableCell>
                      <TableCell>{formatDate(allowance.started_at)}</TableCell>
                      <TableCell>
                        {allowance.ended_at ? (
                          formatDate(allowance.ended_at)
                        ) : (
                          <Badge variant="outline" className="text-green-600 border-green-300">
                            En cours
                          </Badge>
                        )}
                      </TableCell>
                      <TableCell className="max-w-[200px] truncate text-muted-foreground">
                        {allowance.notes || '—'}
                      </TableCell>
                      <TableCell className="text-right">
                        <div className="flex items-center justify-end gap-1">
                          <Button
                            variant="ghost"
                            size="sm"
                            onClick={() => openEditDialog(allowance)}
                          >
                            <Pencil className="h-3.5 w-3.5" />
                          </Button>
                          {isActive && (
                            <Button
                              variant="ghost"
                              size="sm"
                              onClick={() => openEndDialog(allowance)}
                              className="text-muted-foreground hover:text-foreground"
                              title="Terminer le forfait"
                            >
                              <CalendarOff className="h-3.5 w-3.5" />
                            </Button>
                          )}
                        </div>
                      </TableCell>
                    </TableRow>
                  );
                })}
              </TableBody>
            </Table>
          )}
        </CardContent>
      </Card>

      {/* Add/Edit Dialog */}
      <Dialog open={showDialog} onOpenChange={setShowDialog}>
        <DialogContent className="sm:max-w-[480px]">
          <DialogHeader>
            <DialogTitle>
              {editingAllowance ? 'Modifier le forfait' : 'Ajouter un forfait'}
            </DialogTitle>
            <DialogDescription>
              {editingAllowance
                ? 'Modifiez les détails du forfait kilométrage.'
                : 'Définissez un nouveau forfait kilométrage pour un employé.'}
            </DialogDescription>
          </DialogHeader>

          <div className="space-y-4 py-2">
            {/* Employee select */}
            <div className="space-y-2">
              <Label htmlFor="employee">Employé</Label>
              <Select value={formEmployeeId} onValueChange={setFormEmployeeId}>
                <SelectTrigger id="employee">
                  <SelectValue placeholder="Sélectionner un employé" />
                </SelectTrigger>
                <SelectContent>
                  {employees.map((emp) => (
                    <SelectItem key={emp.id} value={emp.id}>
                      {getEmployeeName(emp)}
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
            </div>

            {/* Amount */}
            <div className="space-y-2">
              <Label htmlFor="amount">Montant par période (CAD)</Label>
              <Input
                id="amount"
                type="number"
                min="0"
                step="0.01"
                value={formAmount}
                onChange={(e) => setFormAmount(e.target.value)}
                placeholder="Ex: 150.00"
              />
            </div>

            {/* Start date */}
            <div className="space-y-2">
              <Label htmlFor="started-at">Date de début</Label>
              <Input
                id="started-at"
                type="date"
                value={formStartedAt}
                onChange={(e) => setFormStartedAt(e.target.value)}
              />
            </div>

            {/* End date */}
            <div className="space-y-2">
              <Label htmlFor="ended-at">Date de fin (optionnel)</Label>
              <Input
                id="ended-at"
                type="date"
                value={formEndedAt}
                onChange={(e) => setFormEndedAt(e.target.value)}
              />
              <p className="text-xs text-muted-foreground">
                Laissez vide pour un forfait en cours.
              </p>
            </div>

            {/* Notes */}
            <div className="space-y-2">
              <Label htmlFor="notes">Notes (optionnel)</Label>
              <Textarea
                id="notes"
                value={formNotes}
                onChange={(e) => setFormNotes(e.target.value)}
                placeholder="Ex: Forfait mensuel — région nord"
                rows={3}
              />
            </div>
          </div>

          <DialogFooter>
            <Button variant="outline" onClick={() => setShowDialog(false)} disabled={isSaving}>
              Annuler
            </Button>
            <Button onClick={handleSave} disabled={isSaving}>
              {isSaving ? (
                <>
                  <Loader2 className="h-4 w-4 mr-2 animate-spin" />
                  Enregistrement...
                </>
              ) : editingAllowance ? (
                'Mettre à jour'
              ) : (
                'Ajouter'
              )}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>

      {/* End allowance dialog */}
      <Dialog open={!!endingAllowance} onOpenChange={(open) => !open && setEndingAllowance(null)}>
        <DialogContent className="sm:max-w-[400px]">
          <DialogHeader>
            <DialogTitle>Terminer le forfait</DialogTitle>
            <DialogDescription>
              Définissez la date de fin du forfait de{' '}
              <span className="font-medium">{endingAllowance?.employee?.name || 'cet employé'}</span>.
              Le forfait restera dans l&apos;historique.
            </DialogDescription>
          </DialogHeader>

          <div className="space-y-4 py-2">
            <div className="space-y-2">
              <Label htmlFor="end-date">Date de fin</Label>
              <Input
                id="end-date"
                type="date"
                value={endDate}
                onChange={(e) => setEndDate(e.target.value)}
              />
            </div>
          </div>

          <DialogFooter>
            <Button variant="outline" onClick={() => setEndingAllowance(null)} disabled={isEnding}>
              Annuler
            </Button>
            <Button onClick={handleEndAllowance} disabled={isEnding}>
              {isEnding ? (
                <>
                  <Loader2 className="h-4 w-4 mr-2 animate-spin" />
                  Enregistrement...
                </>
              ) : (
                'Terminer le forfait'
              )}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </div>
  );
}
