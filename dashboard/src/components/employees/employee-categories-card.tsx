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
  AlertDialog,
  AlertDialogAction,
  AlertDialogCancel,
  AlertDialogContent,
  AlertDialogDescription,
  AlertDialogFooter,
  AlertDialogHeader,
  AlertDialogTitle,
} from '@/components/ui/alert-dialog';
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
import { Label } from '@/components/ui/label';
import { Plus, Pencil, Trash2, Briefcase, Loader2, RefreshCw } from 'lucide-react';
import { toast } from 'sonner';
import { supabaseClient } from '@/lib/supabase/client';
import { toLocalDateString } from '@/lib/utils/date-utils';

type CategoryType = 'renovation' | 'entretien' | 'menage' | 'admin';
type StatusFilter = 'all' | 'active' | 'expired';
type CategoryFilter = 'all' | CategoryType;

interface EmployeeCategory {
  id: string;
  employee_id: string;
  category: CategoryType;
  started_at: string;
  ended_at: string | null;
  created_at: string;
  updated_at: string;
}

interface EmployeeCategoriesCardProps {
  employeeId: string;
  isDisabled?: boolean;
}

const CATEGORY_LABELS: Record<CategoryType, string> = {
  renovation: 'Rénovation',
  entretien: 'Entretien',
  menage: 'Ménage',
  admin: 'Administration',
};

const CATEGORY_BADGE_CLASSES: Record<CategoryType, string> = {
  renovation: 'bg-blue-100 text-blue-700 hover:bg-blue-100',
  entretien: 'bg-green-100 text-green-700 hover:bg-green-100',
  menage: 'bg-purple-100 text-purple-700 hover:bg-purple-100',
  admin: 'bg-amber-100 text-amber-700 hover:bg-amber-100',
};

function formatDate(dateStr: string): string {
  const d = new Date(dateStr);
  return d.toLocaleDateString('fr-CA', { month: 'short', day: 'numeric', year: 'numeric' });
}

export function EmployeeCategoriesCard({ employeeId, isDisabled = false }: EmployeeCategoriesCardProps) {
  // Data state
  const [categories, setCategories] = useState<EmployeeCategory[]>([]);
  const [isLoading, setIsLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  // Filter state
  const [categoryFilter, setCategoryFilter] = useState<CategoryFilter>('all');
  const [statusFilter, setStatusFilter] = useState<StatusFilter>('all');

  // Dialog state (add/edit)
  const [showDialog, setShowDialog] = useState(false);
  const [editingCategory, setEditingCategory] = useState<EmployeeCategory | null>(null);
  const [isSaving, setIsSaving] = useState(false);

  // Form state
  const [formCategory, setFormCategory] = useState<CategoryType>('entretien');
  const [formStartedAt, setFormStartedAt] = useState('');
  const [formEndedAt, setFormEndedAt] = useState('');

  // Delete confirmation state
  const [deletingCategory, setDeletingCategory] = useState<EmployeeCategory | null>(null);
  const [isDeleting, setIsDeleting] = useState(false);

  // Fetch categories for this employee
  const fetchCategories = useCallback(async () => {
    setIsLoading(true);
    setError(null);
    try {
      const { data, error: fetchError } = await supabaseClient
        .from('employee_categories')
        .select('*')
        .eq('employee_id', employeeId)
        .order('started_at', { ascending: false });

      if (fetchError) {
        setError(fetchError.message);
        return;
      }

      setCategories((data as EmployeeCategory[]) ?? []);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Erreur lors du chargement');
    } finally {
      setIsLoading(false);
    }
  }, [employeeId]);

  useEffect(() => {
    fetchCategories();
  }, [fetchCategories]);

  // Summary stats
  const stats = useMemo(() => {
    const total = categories.length;
    const active = categories.filter((c) => !c.ended_at).length;
    const expired = categories.filter((c) => !!c.ended_at).length;
    const renovation = categories.filter((c) => c.category === 'renovation').length;
    const entretien = categories.filter((c) => c.category === 'entretien').length;
    const menage = categories.filter((c) => c.category === 'menage').length;
    const admin = categories.filter((c) => c.category === 'admin').length;
    return { total, active, expired, renovation, entretien, menage, admin };
  }, [categories]);

  // Filter categories
  const filteredCategories = useMemo(() => {
    let filtered = categories;
    if (categoryFilter !== 'all') {
      filtered = filtered.filter((c) => c.category === categoryFilter);
    }
    if (statusFilter === 'active') {
      filtered = filtered.filter((c) => !c.ended_at);
    } else if (statusFilter === 'expired') {
      filtered = filtered.filter((c) => !!c.ended_at);
    }
    return filtered;
  }, [categories, categoryFilter, statusFilter]);

  // Open add dialog
  const openAddDialog = useCallback(() => {
    setEditingCategory(null);
    setFormCategory('entretien');
    setFormStartedAt(toLocalDateString(new Date()));
    setFormEndedAt('');
    setShowDialog(true);
  }, []);

  // Open edit dialog
  const openEditDialog = useCallback((cat: EmployeeCategory) => {
    setEditingCategory(cat);
    setFormCategory(cat.category);
    setFormStartedAt(cat.started_at.split('T')[0]);
    setFormEndedAt(cat.ended_at ? cat.ended_at.split('T')[0] : '');
    setShowDialog(true);
  }, []);

  // Save (insert or update)
  const handleSave = useCallback(async () => {
    if (!formStartedAt) {
      toast.error('Veuillez sélectionner une date de début.');
      return;
    }

    setIsSaving(true);
    try {
      const payload = {
        employee_id: employeeId,
        category: formCategory,
        started_at: formStartedAt,
        ended_at: formEndedAt || null,
      };

      if (editingCategory) {
        const { error: updateError } = await supabaseClient
          .from('employee_categories')
          .update(payload)
          .eq('id', editingCategory.id);

        if (updateError) {
          toast.error(`Erreur: ${updateError.message}`);
          return;
        }
        toast.success('Catégorie mise à jour avec succès.');
      } else {
        const { error: insertError } = await supabaseClient
          .from('employee_categories')
          .insert(payload);

        if (insertError) {
          toast.error(`Erreur: ${insertError.message}`);
          return;
        }
        toast.success('Catégorie ajoutée avec succès.');
      }

      setShowDialog(false);
      fetchCategories();
    } catch (err) {
      toast.error(err instanceof Error ? err.message : 'Erreur inattendue');
    } finally {
      setIsSaving(false);
    }
  }, [editingCategory, employeeId, formCategory, formStartedAt, formEndedAt, fetchCategories]);

  // Delete
  const handleDelete = useCallback(async () => {
    if (!deletingCategory) return;

    setIsDeleting(true);
    try {
      const { error: deleteError } = await supabaseClient
        .from('employee_categories')
        .delete()
        .eq('id', deletingCategory.id);

      if (deleteError) {
        toast.error(`Erreur: ${deleteError.message}`);
        return;
      }

      toast.success('Catégorie supprimée avec succès.');
      setDeletingCategory(null);
      fetchCategories();
    } catch (err) {
      toast.error(err instanceof Error ? err.message : 'Erreur inattendue');
    } finally {
      setIsDeleting(false);
    }
  }, [deletingCategory, fetchCategories]);

  return (
    <Card>
      <CardHeader>
        <div className="flex items-center justify-between">
          <CardTitle className="flex items-center gap-2">
            <Briefcase className="h-5 w-5" />
            Catégories de poste
            {categoryFilter !== 'all' && (
              <Badge variant="secondary" className="ml-2 text-xs">
                {CATEGORY_LABELS[categoryFilter as CategoryType]} ({filteredCategories.length})
                <button
                  onClick={(e) => { e.stopPropagation(); setCategoryFilter('all'); }}
                  className="ml-1 hover:text-destructive"
                >
                  &times;
                </button>
              </Badge>
            )}
            {statusFilter !== 'all' && (
              <Badge variant="secondary" className="ml-2 text-xs">
                {statusFilter === 'active' ? 'Active' : 'Expirée'} ({filteredCategories.length})
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
                Active ({stats.active})
              </button>
              <button
                className={`px-3 py-1.5 text-xs font-medium rounded-r-md border-l transition-colors ${
                  statusFilter === 'expired' ? 'bg-primary text-primary-foreground' : 'hover:bg-muted'
                }`}
                onClick={() => setStatusFilter('expired')}
              >
                Expirée ({stats.expired})
              </button>
            </div>

            <Button
              variant="ghost"
              size="sm"
              onClick={fetchCategories}
              disabled={isLoading}
            >
              <RefreshCw className={`h-4 w-4 ${isLoading ? 'animate-spin' : ''}`} />
            </Button>

            {!isDisabled && (
              <Button size="sm" onClick={openAddDialog}>
                <Plus className="h-4 w-4 mr-1" />
                Ajouter
              </Button>
            )}
          </div>
        </div>
      </CardHeader>
      <CardContent>
        {/* Summary stats */}
        <div className="grid grid-cols-4 gap-3 mb-4">
          {(['renovation', 'entretien', 'menage', 'admin'] as CategoryType[]).map((cat) => (
            <button
              key={cat}
              className={`rounded-lg border p-3 text-center transition-colors hover:ring-2 hover:ring-primary/20 ${
                categoryFilter === cat ? 'ring-2 ring-primary' : ''
              }`}
              onClick={() => setCategoryFilter(categoryFilter === cat ? 'all' : cat)}
            >
              <p className="text-xl font-bold">{stats[cat]}</p>
              <p className="text-xs text-muted-foreground mt-0.5">{CATEGORY_LABELS[cat]}</p>
            </button>
          ))}
        </div>

        {error && (
          <div className="rounded-md bg-red-50 p-3 text-sm text-red-700 mb-4">
            {error}
          </div>
        )}

        {isLoading ? (
          <div className="animate-pulse space-y-3">
            {Array.from({ length: 3 }).map((_, i) => (
              <div key={i} className="flex gap-4 py-3">
                <div className="h-4 w-28 rounded bg-slate-200" />
                <div className="h-4 w-24 rounded bg-slate-200" />
                <div className="h-4 w-24 rounded bg-slate-200" />
                <div className="h-4 w-16 rounded bg-slate-200" />
              </div>
            ))}
          </div>
        ) : filteredCategories.length === 0 ? (
          <div className="py-8 text-center text-sm text-muted-foreground">
            {categories.length === 0
              ? 'Aucune catégorie de poste trouvée.'
              : 'Aucune catégorie ne correspond aux filtres sélectionnés.'}
          </div>
        ) : (
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>Catégorie</TableHead>
                <TableHead>Début</TableHead>
                <TableHead>Fin</TableHead>
                {!isDisabled && <TableHead className="text-right">Actions</TableHead>}
              </TableRow>
            </TableHeader>
            <TableBody>
              {filteredCategories.map((cat) => (
                <TableRow key={cat.id}>
                  <TableCell>
                    <Badge className={CATEGORY_BADGE_CLASSES[cat.category]}>
                      {CATEGORY_LABELS[cat.category]}
                    </Badge>
                  </TableCell>
                  <TableCell>{formatDate(cat.started_at)}</TableCell>
                  <TableCell>
                    {cat.ended_at ? (
                      formatDate(cat.ended_at)
                    ) : (
                      <Badge variant="outline" className="text-green-600 border-green-300">
                        En cours
                      </Badge>
                    )}
                  </TableCell>
                  {!isDisabled && (
                    <TableCell className="text-right">
                      <div className="flex items-center justify-end gap-1">
                        <Button
                          variant="ghost"
                          size="sm"
                          onClick={() => openEditDialog(cat)}
                        >
                          <Pencil className="h-3.5 w-3.5" />
                        </Button>
                        <Button
                          variant="ghost"
                          size="sm"
                          onClick={() => setDeletingCategory(cat)}
                          className="text-destructive hover:text-destructive"
                        >
                          <Trash2 className="h-3.5 w-3.5" />
                        </Button>
                      </div>
                    </TableCell>
                  )}
                </TableRow>
              ))}
            </TableBody>
          </Table>
        )}
      </CardContent>

      {/* Add/Edit Dialog */}
      <Dialog open={showDialog} onOpenChange={setShowDialog}>
        <DialogContent className="sm:max-w-[420px]">
          <DialogHeader>
            <DialogTitle>
              {editingCategory ? 'Modifier la catégorie' : 'Ajouter une catégorie'}
            </DialogTitle>
            <DialogDescription>
              {editingCategory
                ? 'Modifiez les détails de la catégorie de poste.'
                : 'Définissez une nouvelle catégorie de poste pour cet employé.'}
            </DialogDescription>
          </DialogHeader>

          <div className="space-y-4 py-2">
            {/* Category select */}
            <div className="space-y-2">
              <Label htmlFor="category">Catégorie</Label>
              <Select value={formCategory} onValueChange={(v) => setFormCategory(v as CategoryType)}>
                <SelectTrigger id="category">
                  <SelectValue />
                </SelectTrigger>
                <SelectContent>
                  {(Object.entries(CATEGORY_LABELS) as [CategoryType, string][]).map(([value, label]) => (
                    <SelectItem key={value} value={value}>
                      {label}
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
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
                Laissez vide pour une catégorie en cours.
              </p>
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
              ) : editingCategory ? (
                'Mettre à jour'
              ) : (
                'Ajouter'
              )}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>

      {/* Delete confirmation dialog */}
      <AlertDialog open={!!deletingCategory} onOpenChange={(open) => !open && setDeletingCategory(null)}>
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>Supprimer la catégorie ?</AlertDialogTitle>
            <AlertDialogDescription>
              Êtes-vous sûr de vouloir supprimer la catégorie{' '}
              <span className="font-medium">
                {deletingCategory ? CATEGORY_LABELS[deletingCategory.category] : ''}
              </span>{' '}
              ? Cette action est irréversible.
            </AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel disabled={isDeleting}>Annuler</AlertDialogCancel>
            <AlertDialogAction
              onClick={handleDelete}
              disabled={isDeleting}
              className="bg-destructive text-destructive-foreground hover:bg-destructive/90"
            >
              {isDeleting ? (
                <>
                  <Loader2 className="h-4 w-4 mr-2 animate-spin" />
                  Suppression...
                </>
              ) : (
                'Supprimer'
              )}
            </AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
    </Card>
  );
}
