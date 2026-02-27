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
  Users,
  ChevronDown,
  ChevronUp,
  Check,
  X,
  RefreshCw,
  AlertTriangle,
  Loader2,
  ArrowRight,
} from 'lucide-react';
import { toast } from 'sonner';
import { supabaseClient } from '@/lib/supabase/client';
import type { CarpoolGroup, CarpoolMember, Trip } from '@/types/mileage';

type StatusFilter = 'all' | 'auto_detected' | 'confirmed' | 'dismissed';

interface EmployeeProfile {
  id: string;
  full_name: string | null;
}

function getDefaultDateFrom(): string {
  const d = new Date();
  d.setDate(d.getDate() - 30);
  return d.toISOString().split('T')[0];
}

function getDefaultDateTo(): string {
  return new Date().toISOString().split('T')[0];
}

function formatDate(dateStr: string): string {
  const d = new Date(dateStr + 'T00:00:00');
  return d.toLocaleDateString('fr-CA', { day: 'numeric', month: 'short', year: 'numeric' });
}

function formatTime(dateStr: string): string {
  const d = new Date(dateStr);
  return d.toLocaleTimeString('fr-CA', { hour: '2-digit', minute: '2-digit' });
}

function formatDistance(km: number | null): string {
  if (km == null) return '\u2014';
  return `${km.toFixed(1)} km`;
}

function statusLabel(status: CarpoolGroup['status']): string {
  switch (status) {
    case 'auto_detected':
      return 'D\u00e9tect\u00e9';
    case 'confirmed':
      return 'Confirm\u00e9';
    case 'dismissed':
      return 'Rejet\u00e9';
  }
}

function statusBadgeClasses(status: CarpoolGroup['status']): string {
  switch (status) {
    case 'auto_detected':
      return 'bg-yellow-100 text-yellow-700 hover:bg-yellow-100';
    case 'confirmed':
      return 'bg-green-100 text-green-700 hover:bg-green-100';
    case 'dismissed':
      return 'bg-gray-100 text-gray-500 hover:bg-gray-100';
  }
}

function roleBadgeClasses(role: CarpoolMember['role']): string {
  switch (role) {
    case 'driver':
      return 'bg-blue-100 text-blue-700 hover:bg-blue-100';
    case 'passenger':
      return 'bg-slate-100 text-slate-600 hover:bg-slate-100';
    case 'unassigned':
      return 'bg-gray-100 text-gray-400 hover:bg-gray-100';
  }
}

function roleLabel(role: CarpoolMember['role']): string {
  switch (role) {
    case 'driver':
      return 'Conducteur';
    case 'passenger':
      return 'Passager';
    case 'unassigned':
      return 'Non assign\u00e9';
  }
}

export function CarpoolingTab() {
  // Filters
  const [dateFrom, setDateFrom] = useState(getDefaultDateFrom);
  const [dateTo, setDateTo] = useState(getDefaultDateTo);
  const [statusFilter, setStatusFilter] = useState<StatusFilter>('all');
  const [reviewOnlyToggle, setReviewOnlyToggle] = useState(false);

  // Data
  const [groups, setGroups] = useState<CarpoolGroup[]>([]);
  const [isLoading, setIsLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  // Expanded groups
  const [expandedGroupId, setExpandedGroupId] = useState<string | null>(null);

  // Re-detect dialog
  const [showDetectDialog, setShowDetectDialog] = useState(false);
  const [detectDateFrom, setDetectDateFrom] = useState(getDefaultDateFrom);
  const [detectDateTo, setDetectDateTo] = useState(getDefaultDateTo);
  const [isDetecting, setIsDetecting] = useState(false);
  const [detectProgress, setDetectProgress] = useState<string | null>(null);

  // Driver change state
  const [changingDriverGroupId, setChangingDriverGroupId] = useState<string | null>(null);

  // Action loading
  const [actionLoadingGroupId, setActionLoadingGroupId] = useState<string | null>(null);

  // Fetch carpool groups with separate queries + client-side merge
  const fetchGroups = useCallback(async () => {
    setIsLoading(true);
    setError(null);
    try {
      // 1. Fetch carpool_groups
      let groupQuery = supabaseClient
        .from('carpool_groups')
        .select('*')
        .order('trip_date', { ascending: false })
        .limit(100);

      if (dateFrom) {
        groupQuery = groupQuery.gte('trip_date', dateFrom);
      }
      if (dateTo) {
        groupQuery = groupQuery.lte('trip_date', dateTo);
      }

      const { data: groupsData, error: groupsError } = await groupQuery;

      if (groupsError) {
        setError(groupsError.message);
        setGroups([]);
        return;
      }

      if (!groupsData || groupsData.length === 0) {
        setGroups([]);
        return;
      }

      const groupIds = groupsData.map((g) => g.id);

      // 2. Fetch carpool_members for those group IDs
      const { data: membersData, error: membersError } = await supabaseClient
        .from('carpool_members')
        .select('*')
        .in('carpool_group_id', groupIds);

      if (membersError) {
        setError(membersError.message);
        setGroups([]);
        return;
      }

      // 3. Fetch trips for the trip IDs found in members
      const tripIds = [...new Set((membersData || []).map((m) => m.trip_id).filter(Boolean))];
      const tripMap: Record<string, Trip> = {};

      if (tripIds.length > 0) {
        const { data: tripsData } = await supabaseClient
          .from('trips')
          .select('*')
          .in('id', tripIds);

        if (tripsData) {
          for (const t of tripsData) {
            tripMap[t.id] = t as Trip;
          }
        }
      }

      // 4. Fetch employee_profiles (id, full_name) for all employee IDs
      // Collect employee IDs from members + driver_employee_id from groups
      const employeeIds = [
        ...new Set([
          ...(membersData || []).map((m) => m.employee_id).filter(Boolean),
          ...groupsData.map((g) => g.driver_employee_id).filter(Boolean),
        ]),
      ];
      const employeeMap: Record<string, EmployeeProfile> = {};

      if (employeeIds.length > 0) {
        const { data: employees } = await supabaseClient
          .from('employee_profiles')
          .select('id, full_name')
          .in('id', employeeIds);

        if (employees) {
          for (const emp of employees) {
            employeeMap[emp.id] = emp as EmployeeProfile;
          }
        }
      }

      // 5. Merge members into groups
      const membersMap: Record<string, CarpoolMember[]> = {};
      for (const member of membersData || []) {
        const emp = employeeMap[member.employee_id];
        const trip = tripMap[member.trip_id];
        const enrichedMember: CarpoolMember = {
          ...member,
          employee: emp ? { id: emp.id, name: emp.full_name || emp.id } : undefined,
          trip: trip || undefined,
        };

        if (!membersMap[member.carpool_group_id]) {
          membersMap[member.carpool_group_id] = [];
        }
        membersMap[member.carpool_group_id].push(enrichedMember);
      }

      const mergedGroups: CarpoolGroup[] = groupsData.map((group) => {
        const driverEmp = group.driver_employee_id
          ? employeeMap[group.driver_employee_id]
          : null;
        return {
          ...group,
          members: membersMap[group.id] || [],
          driver: driverEmp
            ? { id: driverEmp.id, name: driverEmp.full_name || driverEmp.id }
            : undefined,
        } as CarpoolGroup;
      });

      setGroups(mergedGroups);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Erreur lors du chargement');
      setGroups([]);
    } finally {
      setIsLoading(false);
    }
  }, [dateFrom, dateTo]);

  useEffect(() => {
    fetchGroups();
  }, [fetchGroups]);

  // Filtered groups
  const filteredGroups = useMemo(() => {
    let filtered = groups;
    if (statusFilter !== 'all') {
      filtered = filtered.filter((g) => g.status === statusFilter);
    }
    if (reviewOnlyToggle) {
      filtered = filtered.filter((g) => g.review_needed);
    }
    return filtered;
  }, [groups, statusFilter, reviewOnlyToggle]);

  // Stats
  const stats = useMemo(() => {
    const total = groups.length;
    const reviewNeeded = groups.filter((g) => g.review_needed).length;
    const confirmed = groups.filter((g) => g.status === 'confirmed').length;
    return { total, reviewNeeded, confirmed };
  }, [groups]);

  // Actions
  const handleUpdateStatus = useCallback(
    async (groupId: string, newStatus: 'confirmed' | 'dismissed') => {
      setActionLoadingGroupId(groupId);
      try {
        const { error: rpcError } = await supabaseClient.rpc('update_carpool_group', {
          p_group_id: groupId,
          p_status: newStatus,
        });
        if (rpcError) throw rpcError;
        toast.success(
          newStatus === 'confirmed'
            ? 'Covoiturage confirm\u00e9'
            : 'Covoiturage rejet\u00e9'
        );
        fetchGroups();
      } catch (err) {
        toast.error(
          err instanceof Error ? err.message : 'Erreur lors de la mise \u00e0 jour'
        );
      } finally {
        setActionLoadingGroupId(null);
      }
    },
    [fetchGroups]
  );

  const handleChangeDriver = useCallback(
    async (groupId: string, newDriverEmployeeId: string) => {
      setActionLoadingGroupId(groupId);
      try {
        const { error: rpcError } = await supabaseClient.rpc('update_carpool_group', {
          p_group_id: groupId,
          p_driver_employee_id: newDriverEmployeeId,
        });
        if (rpcError) throw rpcError;
        toast.success('Conducteur modifi\u00e9');
        setChangingDriverGroupId(null);
        fetchGroups();
      } catch (err) {
        toast.error(
          err instanceof Error ? err.message : 'Erreur lors du changement de conducteur'
        );
      } finally {
        setActionLoadingGroupId(null);
      }
    },
    [fetchGroups]
  );

  // Re-detect carpools
  const handleRedetect = useCallback(async () => {
    setIsDetecting(true);
    setDetectProgress(null);

    const start = new Date(detectDateFrom);
    const end = new Date(detectDateTo);
    if (start > end) {
      toast.error('La date de d\u00e9but doit \u00eatre avant la date de fin');
      setIsDetecting(false);
      return;
    }

    const dates: string[] = [];
    const current = new Date(start);
    while (current <= end) {
      dates.push(current.toISOString().split('T')[0]);
      current.setDate(current.getDate() + 1);
    }

    let successCount = 0;
    let errorCount = 0;
    let totalDetected = 0;

    for (let i = 0; i < dates.length; i++) {
      const date = dates[i];
      setDetectProgress(`Jour ${i + 1}/${dates.length}: ${date}...`);

      try {
        const { data, error: rpcError } = await supabaseClient.rpc('detect_carpools', {
          p_date: date,
        });
        if (rpcError) {
          errorCount++;
        } else {
          successCount++;
          if (typeof data === 'number') {
            totalDetected += data;
          } else if (data && typeof data === 'object' && 'groups_created' in data) {
            totalDetected += (data as { groups_created: number }).groups_created;
          }
        }
      } catch {
        errorCount++;
      }
    }

    setIsDetecting(false);
    setDetectProgress(null);
    setShowDetectDialog(false);

    if (errorCount === 0) {
      toast.success(
        `D\u00e9tection termin\u00e9e: ${totalDetected} groupe(s) cr\u00e9\u00e9(s) sur ${successCount} jour(s)`
      );
    } else {
      toast.warning(
        `D\u00e9tection partielle: ${totalDetected} groupe(s), ${errorCount} jour(s) en erreur`
      );
    }

    fetchGroups();
  }, [detectDateFrom, detectDateTo, fetchGroups]);

  return (
    <div className="space-y-4">
      {/* Re-detect button + Filter bar */}
      <Card>
        <CardContent className="pt-4 pb-4">
          <div className="flex flex-wrap items-end gap-4">
            <div className="flex flex-col gap-1">
              <label className="text-xs font-medium text-muted-foreground">Date d&eacute;but</label>
              <input
                type="date"
                className="h-9 rounded-md border border-input bg-background px-3 text-sm ring-offset-background focus:outline-none focus:ring-2 focus:ring-ring focus:ring-offset-2"
                value={dateFrom}
                onChange={(e) => setDateFrom(e.target.value)}
              />
            </div>

            <div className="flex flex-col gap-1">
              <label className="text-xs font-medium text-muted-foreground">Date fin</label>
              <input
                type="date"
                className="h-9 rounded-md border border-input bg-background px-3 text-sm ring-offset-background focus:outline-none focus:ring-2 focus:ring-ring focus:ring-offset-2"
                value={dateTo}
                onChange={(e) => setDateTo(e.target.value)}
              />
            </div>

            <div className="flex flex-col gap-1">
              <label className="text-xs font-medium text-muted-foreground">Statut</label>
              <select
                className="h-9 rounded-md border border-input bg-background px-3 text-sm ring-offset-background focus:outline-none focus:ring-2 focus:ring-ring focus:ring-offset-2"
                value={statusFilter}
                onChange={(e) => setStatusFilter(e.target.value as StatusFilter)}
              >
                <option value="all">Tous</option>
                <option value="auto_detected">D&eacute;tect&eacute;</option>
                <option value="confirmed">Confirm&eacute;</option>
                <option value="dismissed">Rejet&eacute;</option>
              </select>
            </div>

            <Button
              variant={reviewOnlyToggle ? 'default' : 'outline'}
              size="sm"
              onClick={() => setReviewOnlyToggle(!reviewOnlyToggle)}
              className="h-9"
            >
              <AlertTriangle className="h-4 w-4 mr-1" />
              &Agrave; r&eacute;viser
            </Button>

            <div className="ml-auto flex items-center gap-2">
              <Button
                variant="outline"
                size="sm"
                onClick={() => {
                  setDetectDateFrom(dateFrom);
                  setDetectDateTo(dateTo);
                  setShowDetectDialog(true);
                }}
              >
                <RefreshCw className="h-4 w-4 mr-1" />
                Re-d&eacute;tecter
              </Button>
              <Button
                variant="ghost"
                size="sm"
                onClick={fetchGroups}
                disabled={isLoading}
              >
                <RefreshCw className={`h-4 w-4 ${isLoading ? 'animate-spin' : ''}`} />
              </Button>
            </div>
          </div>
        </CardContent>
      </Card>

      {/* Stats row */}
      <div className="grid grid-cols-3 gap-4">
        <Card>
          <CardContent className="pt-4 pb-3 text-center">
            <p className="text-2xl font-bold">{stats.total}</p>
            <p className="text-xs text-muted-foreground">Total groupes</p>
          </CardContent>
        </Card>
        <Card>
          <CardContent className="pt-4 pb-3 text-center">
            <div className="flex items-center justify-center gap-1.5 mb-0.5">
              <AlertTriangle className="h-4 w-4 text-red-500" />
              <p className="text-2xl font-bold text-red-600">{stats.reviewNeeded}</p>
            </div>
            <p className="text-xs text-muted-foreground">&Agrave; r&eacute;viser</p>
          </CardContent>
        </Card>
        <Card>
          <CardContent className="pt-4 pb-3 text-center">
            <div className="flex items-center justify-center gap-1.5 mb-0.5">
              <Check className="h-4 w-4 text-green-500" />
              <p className="text-2xl font-bold text-green-600">{stats.confirmed}</p>
            </div>
            <p className="text-xs text-muted-foreground">Confirm&eacute;s</p>
          </CardContent>
        </Card>
      </div>

      {/* Groups list */}
      <Card>
        <CardHeader>
          <CardTitle className="flex items-center gap-2">
            <Users className="h-5 w-5" />
            Groupes de covoiturage
            {filteredGroups.length !== groups.length && (
              <Badge variant="secondary" className="ml-2 text-xs">
                {filteredGroups.length} / {groups.length}
              </Badge>
            )}
          </CardTitle>
        </CardHeader>
        <CardContent>
          {error && (
            <div className="rounded-md bg-red-50 p-3 text-sm text-red-700 mb-4">
              {error}
            </div>
          )}

          {isLoading ? (
            <div className="flex items-center justify-center py-12">
              <Loader2 className="h-6 w-6 animate-spin text-muted-foreground" />
            </div>
          ) : filteredGroups.length === 0 ? (
            <div className="py-8 text-center text-sm text-muted-foreground">
              Aucun groupe de covoiturage trouv&eacute; pour les filtres s&eacute;lectionn&eacute;s.
            </div>
          ) : (
            <div className="space-y-3">
              {filteredGroups.map((group) => {
                const isExpanded = expandedGroupId === group.id;
                const memberCount = group.members?.length || 0;
                const isActionLoading = actionLoadingGroupId === group.id;

                return (
                  <div
                    key={group.id}
                    className="border rounded-lg overflow-hidden"
                  >
                    {/* Group header (clickable) */}
                    <div
                      className="flex items-center gap-3 px-4 py-3 cursor-pointer hover:bg-muted/50 transition-colors"
                      onClick={() =>
                        setExpandedGroupId(isExpanded ? null : group.id)
                      }
                    >
                      {isExpanded ? (
                        <ChevronUp className="h-4 w-4 text-muted-foreground flex-shrink-0" />
                      ) : (
                        <ChevronDown className="h-4 w-4 text-muted-foreground flex-shrink-0" />
                      )}

                      <div className="flex-1 min-w-0">
                        <div className="flex items-center gap-2 flex-wrap">
                          <span className="font-medium text-sm">
                            {formatDate(group.trip_date)}
                          </span>
                          <Badge className={statusBadgeClasses(group.status)}>
                            {statusLabel(group.status)}
                          </Badge>
                          {group.review_needed && (
                            <Badge className="bg-red-100 text-red-700 hover:bg-red-100">
                              <AlertTriangle className="h-3 w-3" />
                              &Agrave; r&eacute;viser
                            </Badge>
                          )}
                          <span className="text-xs text-muted-foreground">
                            {memberCount} membre{memberCount !== 1 ? 's' : ''}
                          </span>
                        </div>
                        <div className="text-xs text-muted-foreground mt-0.5">
                          Conducteur:{' '}
                          {group.driver ? (
                            <span className="font-medium text-foreground">
                              {group.driver.name}
                            </span>
                          ) : (
                            <span className="text-red-500 font-medium">Non assign&eacute;</span>
                          )}
                        </div>
                      </div>

                      {/* Actions (stop propagation to prevent expand toggle) */}
                      <div
                        className="flex items-center gap-1.5 flex-shrink-0"
                        onClick={(e) => e.stopPropagation()}
                      >
                        {group.status !== 'confirmed' && (
                          <Button
                            size="sm"
                            variant="outline"
                            className="h-7 text-xs text-green-700 border-green-200 hover:bg-green-50"
                            disabled={isActionLoading}
                            onClick={() => handleUpdateStatus(group.id, 'confirmed')}
                          >
                            {isActionLoading ? (
                              <Loader2 className="h-3 w-3 animate-spin" />
                            ) : (
                              <Check className="h-3 w-3 mr-1" />
                            )}
                            Confirmer
                          </Button>
                        )}
                        {group.status !== 'dismissed' && (
                          <Button
                            size="sm"
                            variant="outline"
                            className="h-7 text-xs text-gray-500 border-gray-200 hover:bg-gray-50"
                            disabled={isActionLoading}
                            onClick={() => handleUpdateStatus(group.id, 'dismissed')}
                          >
                            {isActionLoading ? (
                              <Loader2 className="h-3 w-3 animate-spin" />
                            ) : (
                              <X className="h-3 w-3 mr-1" />
                            )}
                            Rejeter
                          </Button>
                        )}
                      </div>
                    </div>

                    {/* Expanded content */}
                    {isExpanded && (
                      <div className="border-t px-4 py-3 bg-muted/20 space-y-3">
                        {/* Review note */}
                        {group.review_note && (
                          <div className="rounded-md bg-amber-50 p-2.5 text-sm text-amber-800">
                            <span className="font-medium">Note de r&eacute;vision:</span>{' '}
                            {group.review_note}
                          </div>
                        )}

                        {/* Change driver */}
                        <div className="flex items-center gap-2" onClick={(e) => e.stopPropagation()}>
                          <span className="text-xs text-muted-foreground">
                            Changer conducteur:
                          </span>
                          {changingDriverGroupId === group.id ? (
                            <Select
                              value={group.driver_employee_id || ''}
                              onValueChange={(value) =>
                                handleChangeDriver(group.id, value)
                              }
                            >
                              <SelectTrigger className="h-7 text-xs w-[200px]">
                                <SelectValue placeholder="S&eacute;lectionner..." />
                              </SelectTrigger>
                              <SelectContent>
                                {(group.members || []).map((member) => (
                                  <SelectItem
                                    key={member.employee_id}
                                    value={member.employee_id}
                                  >
                                    {member.employee?.name || member.employee_id}
                                  </SelectItem>
                                ))}
                              </SelectContent>
                            </Select>
                          ) : (
                            <Button
                              size="sm"
                              variant="ghost"
                              className="h-7 text-xs"
                              onClick={() => setChangingDriverGroupId(group.id)}
                            >
                              <Users className="h-3 w-3 mr-1" />
                              Modifier
                            </Button>
                          )}
                          {changingDriverGroupId === group.id && (
                            <Button
                              size="sm"
                              variant="ghost"
                              className="h-7 text-xs"
                              onClick={() => setChangingDriverGroupId(null)}
                            >
                              Annuler
                            </Button>
                          )}
                        </div>

                        {/* Members list */}
                        <div className="space-y-2">
                          <span className="text-xs font-medium text-muted-foreground">
                            Membres
                          </span>
                          <div className="overflow-x-auto">
                            <table className="w-full text-sm">
                              <thead className="border-b bg-muted/50">
                                <tr>
                                  <th className="px-3 py-2 text-left font-medium text-muted-foreground">
                                    Employ&eacute;
                                  </th>
                                  <th className="px-3 py-2 text-left font-medium text-muted-foreground">
                                    R&ocirc;le
                                  </th>
                                  <th className="px-3 py-2 text-left font-medium text-muted-foreground">
                                    Itin&eacute;raire
                                  </th>
                                  <th className="px-3 py-2 text-right font-medium text-muted-foreground">
                                    Distance
                                  </th>
                                </tr>
                              </thead>
                              <tbody className="divide-y">
                                {(group.members || []).map((member) => (
                                  <tr key={member.id}>
                                    <td className="px-3 py-2 font-medium">
                                      {member.employee?.name || member.employee_id}
                                    </td>
                                    <td className="px-3 py-2">
                                      <Badge className={roleBadgeClasses(member.role)}>
                                        {roleLabel(member.role)}
                                      </Badge>
                                    </td>
                                    <td className="px-3 py-2 text-xs text-muted-foreground">
                                      {member.trip ? (
                                        <div className="flex items-center gap-1">
                                          <span className="truncate max-w-[150px]">
                                            {member.trip.start_address ||
                                              `${member.trip.start_latitude?.toFixed(3)}, ${member.trip.start_longitude?.toFixed(3)}`}
                                          </span>
                                          <ArrowRight className="h-3 w-3 flex-shrink-0" />
                                          <span className="truncate max-w-[150px]">
                                            {member.trip.end_address ||
                                              `${member.trip.end_latitude?.toFixed(3)}, ${member.trip.end_longitude?.toFixed(3)}`}
                                          </span>
                                        </div>
                                      ) : (
                                        <span className="text-gray-400">\u2014</span>
                                      )}
                                    </td>
                                    <td className="px-3 py-2 text-right tabular-nums">
                                      {member.trip
                                        ? formatDistance(
                                            member.trip.road_distance_km ??
                                              member.trip.distance_km
                                          )
                                        : '\u2014'}
                                    </td>
                                  </tr>
                                ))}
                              </tbody>
                            </table>
                          </div>
                        </div>

                        {/* Reviewed info */}
                        {group.reviewed_by && group.reviewed_at && (
                          <div className="text-xs text-muted-foreground pt-1 border-t">
                            R&eacute;vis&eacute; le{' '}
                            {formatDate(group.reviewed_at)}{' '}
                            {formatTime(group.reviewed_at)}
                          </div>
                        )}
                      </div>
                    )}
                  </div>
                );
              })}
            </div>
          )}
        </CardContent>
      </Card>

      {/* Re-detect dialog */}
      <Dialog open={showDetectDialog} onOpenChange={setShowDetectDialog}>
        <DialogContent className="sm:max-w-[420px]">
          <DialogHeader>
            <DialogTitle>Re-d&eacute;tecter les covoiturages</DialogTitle>
            <DialogDescription>
              Lancer la d&eacute;tection automatique de covoiturages pour chaque jour
              de la p&eacute;riode s&eacute;lectionn&eacute;e.
            </DialogDescription>
          </DialogHeader>

          <div className="space-y-3 py-2">
            <div className="flex flex-col gap-1">
              <label className="text-xs font-medium text-muted-foreground">Date d&eacute;but</label>
              <input
                type="date"
                className="h-9 rounded-md border border-input bg-background px-3 text-sm ring-offset-background focus:outline-none focus:ring-2 focus:ring-ring focus:ring-offset-2"
                value={detectDateFrom}
                onChange={(e) => setDetectDateFrom(e.target.value)}
                disabled={isDetecting}
              />
            </div>
            <div className="flex flex-col gap-1">
              <label className="text-xs font-medium text-muted-foreground">Date fin</label>
              <input
                type="date"
                className="h-9 rounded-md border border-input bg-background px-3 text-sm ring-offset-background focus:outline-none focus:ring-2 focus:ring-ring focus:ring-offset-2"
                value={detectDateTo}
                onChange={(e) => setDetectDateTo(e.target.value)}
                disabled={isDetecting}
              />
            </div>

            {isDetecting && detectProgress && (
              <div className="flex items-center gap-2 text-sm text-muted-foreground">
                <Loader2 className="h-4 w-4 animate-spin" />
                {detectProgress}
              </div>
            )}
          </div>

          <DialogFooter>
            <Button
              variant="outline"
              onClick={() => setShowDetectDialog(false)}
              disabled={isDetecting}
            >
              Annuler
            </Button>
            <Button onClick={handleRedetect} disabled={isDetecting}>
              {isDetecting ? (
                <>
                  <Loader2 className="h-4 w-4 mr-2 animate-spin" />
                  D&eacute;tection...
                </>
              ) : (
                <>
                  <RefreshCw className="h-4 w-4 mr-2" />
                  Lancer la d&eacute;tection
                </>
              )}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </div>
  );
}
