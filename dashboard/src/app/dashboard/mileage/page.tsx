'use client';

import { useState, useCallback } from 'react';
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
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuTrigger,
} from '@/components/ui/dropdown-menu';
import { Tabs, TabsList, TabsTrigger, TabsContent } from '@/components/ui/tabs';
import {
  RefreshCw,
  CheckCircle,
  AlertTriangle,
  XCircle,
  Loader2,
  MapPin,
  Settings,
} from 'lucide-react';
import { toast } from 'sonner';
import { supabaseClient } from '@/lib/supabase/client';
import { ActivityTab } from '@/components/mileage/activity-tab';
import { VehiclePeriodsTab } from '@/components/mileage/vehicle-periods-tab';
import { CarpoolingTab } from '@/components/mileage/carpooling-tab';

interface BatchResult {
  trip_id: string;
  status: 'matched' | 'failed' | 'anomalous' | 'skipped';
  road_distance_km: number | null;
  match_confidence: number | null;
  error: string | null;
}

interface BatchSummary {
  total_requested: number;
  processed: number;
  matched: number;
  failed: number;
  anomalous: number;
  skipped: number;
  duration_seconds: number;
}

interface BatchResponse {
  success: boolean;
  summary: BatchSummary;
  results: BatchResult[];
  error?: string;
  code?: string;
}

export default function MileagePage() {
  const [activeTab, setActiveTab] = useState('activity');
  const [isProcessing, setIsProcessing] = useState(false);
  const [showDialog, setShowDialog] = useState(false);
  const [dialogMode, setDialogMode] = useState<'failed' | 'all'>('failed');
  const [batchResult, setBatchResult] = useState<BatchResponse | null>(null);
  const [batchError, setBatchError] = useState<string | null>(null);
  const [isRematching, setIsRematching] = useState(false);

  const handleRematchLocations = async () => {
    setIsRematching(true);
    try {
      const { data, error } = await supabaseClient.rpc('rematch_all_trip_locations');
      if (error) throw error;
      const result = Array.isArray(data) ? data[0] : data;
      toast.success(
        `Re-match termin\u00e9: ${result.matched_count} associ\u00e9s, ${result.skipped_manual} manuels ignor\u00e9s`
      );
    } catch (err) {
      toast.error('Erreur lors du re-match des emplacements');
    } finally {
      setIsRematching(false);
    }
  };

  const handleReprocess = useCallback(
    async (mode: 'failed' | 'all') => {
      setIsProcessing(true);
      setBatchError(null);
      setBatchResult(null);

      try {
        const body =
          mode === 'failed'
            ? { reprocess_failed: true, limit: 500 }
            : { reprocess_all: true, limit: 500 };

        const supabaseUrl = process.env.NEXT_PUBLIC_SUPABASE_URL!.trim();
        const anonKey = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!.trim();

        const res = await fetch(`${supabaseUrl}/functions/v1/batch-match-trips`, {
          method: 'POST',
          headers: {
            'Content-Type': 'application/json',
            Authorization: `Bearer ${anonKey}`,
            apikey: anonKey,
          },
          body: JSON.stringify(body),
        });

        if (!res.ok) {
          const errorText = await res.text();
          setBatchError(`HTTP ${res.status}: ${errorText}`);
          return;
        }

        const response = (await res.json()) as BatchResponse;
        if (!response.success && response.error) {
          setBatchError(response.error);
          return;
        }

        setBatchResult(response);
      } catch (err) {
        setBatchError(err instanceof Error ? err.message : 'Une erreur inattendue est survenue');
      } finally {
        setIsProcessing(false);
      }
    },
    []
  );

  const handleProcessPending = useCallback(async () => {
    setIsProcessing(true);
    const toastId = toast.loading('Traitement des trajets en attente...');
    try {
      const supabaseUrl = process.env.NEXT_PUBLIC_SUPABASE_URL!.trim();
      const anonKey = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!.trim();

      const res = await fetch(`${supabaseUrl}/functions/v1/batch-match-trips`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          Authorization: `Bearer ${anonKey}`,
          apikey: anonKey,
        },
        body: JSON.stringify({ reprocess_failed: true, limit: 500 }),
      });

      if (!res.ok) {
        const errorText = await res.text();
        toast.error(`Erreur HTTP ${res.status}: ${errorText}`, { id: toastId });
        return;
      }

      const response = (await res.json()) as BatchResponse;
      if (!response.success && response.error) {
        toast.error(response.error, { id: toastId });
        return;
      }

      const s = response.summary;
      if (s.total_requested === 0) {
        toast.info('Aucun trajet en attente \u00e0 traiter.', { id: toastId });
      } else {
        toast.success(
          `${s.matched} appari\u00e9(s), ${s.failed} \u00e9chou\u00e9(s), ${s.skipped} ignor\u00e9(s) \u2014 ${s.duration_seconds}s`,
          { id: toastId }
        );
      }
    } catch (err) {
      toast.error(err instanceof Error ? err.message : 'Erreur inattendue', { id: toastId });
    } finally {
      setIsProcessing(false);
    }
  }, []);

  const openDialog = useCallback((mode: 'failed' | 'all') => {
    setDialogMode(mode);
    setBatchResult(null);
    setBatchError(null);
    setShowDialog(true);
  }, []);

  const startProcessing = useCallback(() => {
    handleReprocess(dialogMode);
  }, [dialogMode, handleReprocess]);

  return (
    <div className="space-y-6">
      <div className="flex justify-between items-center">
        <div>
          <h1 className="text-2xl font-bold tracking-tight">Kilom&eacute;trage</h1>
          <p className="text-muted-foreground">
            G&eacute;rer l&apos;appariement des itin&eacute;raires et le suivi du kilom&eacute;trage
          </p>
        </div>
        <DropdownMenu>
          <DropdownMenuTrigger asChild>
            <Button variant="outline" disabled={isProcessing || isRematching}>
              {(isProcessing || isRematching) ? (
                <Loader2 className="h-4 w-4 mr-2 animate-spin" />
              ) : (
                <Settings className="h-4 w-4 mr-2" />
              )}
              Actions
            </Button>
          </DropdownMenuTrigger>
          <DropdownMenuContent align="end">
            <DropdownMenuItem onClick={handleProcessPending} disabled={isProcessing}>
              Traiter les en attente
            </DropdownMenuItem>
            <DropdownMenuItem onClick={() => openDialog('failed')} disabled={isProcessing}>
              Retraiter les trajets &eacute;chou&eacute;s
            </DropdownMenuItem>
            <DropdownMenuItem onClick={() => openDialog('all')} disabled={isProcessing}>
              Retraiter tous les trajets
            </DropdownMenuItem>
            <DropdownMenuItem onClick={handleRematchLocations} disabled={isRematching}>
              <MapPin className="h-4 w-4 mr-2" />
              Re-match emplacements
            </DropdownMenuItem>
          </DropdownMenuContent>
        </DropdownMenu>
      </div>

      <Tabs value={activeTab} onValueChange={setActiveTab}>
        <TabsList>
          <TabsTrigger value="activity">Activit&eacute;</TabsTrigger>
          <TabsTrigger value="vehicles">V&eacute;hicules</TabsTrigger>
          <TabsTrigger value="carpools">Covoiturages</TabsTrigger>
        </TabsList>

        <TabsContent value="activity" className="mt-4">
          <ActivityTab />
        </TabsContent>

        <TabsContent value="vehicles" className="mt-4">
          <VehiclePeriodsTab />
        </TabsContent>

        <TabsContent value="carpools" className="mt-4">
          <CarpoolingTab />
        </TabsContent>
      </Tabs>

      {/* Batch Processing Dialog */}
      <Dialog open={showDialog} onOpenChange={setShowDialog}>
        <DialogContent className="sm:max-w-[480px]">
          <DialogHeader>
            <DialogTitle>
              {dialogMode === 'failed'
                ? 'Retraiter les trajets \u00e9chou\u00e9s'
                : 'Retraiter tous les trajets'}
            </DialogTitle>
            <DialogDescription>
              {dialogMode === 'failed'
                ? 'Cela va retenter l\'appariement des itin\u00e9raires pour tous les trajets en attente et \u00e9chou\u00e9s (jusqu\'\u00e0 500).'
                : 'Cela va retraiter TOUS les trajets, y compris ceux d\u00e9j\u00e0 appari\u00e9s (jusqu\'\u00e0 500). Les appariements existants seront \u00e9cras\u00e9s.'}
            </DialogDescription>
          </DialogHeader>

          {batchError && (
            <div className="rounded-md bg-red-50 p-3 text-sm text-red-700">
              {batchError}
            </div>
          )}

          {isProcessing && (
            <div className="flex items-center justify-center py-8">
              <div className="text-center space-y-3">
                <Loader2 className="h-8 w-8 animate-spin mx-auto text-blue-500" />
                <p className="text-sm text-muted-foreground">
                  Traitement des trajets en cours... Cela peut prendre quelques minutes.
                </p>
              </div>
            </div>
          )}

          {batchResult && batchResult.summary && (
            <div className="space-y-4">
              <div className="grid grid-cols-2 gap-3">
                <div className="rounded-lg border p-3 text-center">
                  <p className="text-2xl font-bold">{batchResult.summary.total_requested}</p>
                  <p className="text-xs text-muted-foreground">Total trajets</p>
                </div>
                <div className="rounded-lg border p-3 text-center">
                  <p className="text-2xl font-bold">{batchResult.summary.duration_seconds}s</p>
                  <p className="text-xs text-muted-foreground">Dur&eacute;e</p>
                </div>
              </div>

              <div className="flex flex-wrap gap-2">
                <Badge className="bg-green-100 text-green-700 hover:bg-green-100">
                  <CheckCircle className="h-3 w-3 mr-1" />
                  {batchResult.summary.matched} appari&eacute;s
                </Badge>
                <Badge className="bg-gray-100 text-gray-600 hover:bg-gray-100">
                  {batchResult.summary.skipped} ignor&eacute;s
                </Badge>
                <Badge className="bg-red-100 text-red-700 hover:bg-red-100">
                  <XCircle className="h-3 w-3 mr-1" />
                  {batchResult.summary.failed} &eacute;chou&eacute;s
                </Badge>
                {batchResult.summary.anomalous > 0 && (
                  <Badge className="bg-yellow-100 text-yellow-700 hover:bg-yellow-100">
                    <AlertTriangle className="h-3 w-3 mr-1" />
                    {batchResult.summary.anomalous} anomalies
                  </Badge>
                )}
              </div>

              {batchResult.summary.total_requested === 0 && (
                <p className="text-sm text-muted-foreground text-center py-2">
                  Aucun trajet &agrave; traiter.
                </p>
              )}
            </div>
          )}

          <DialogFooter>
            {!batchResult ? (
              <>
                <Button variant="outline" onClick={() => setShowDialog(false)}>
                  Annuler
                </Button>
                <Button onClick={startProcessing} disabled={isProcessing}>
                  {isProcessing ? (
                    <>
                      <Loader2 className="h-4 w-4 mr-2 animate-spin" />
                      Traitement...
                    </>
                  ) : (
                    'Lancer le traitement'
                  )}
                </Button>
              </>
            ) : (
              <Button onClick={() => setShowDialog(false)}>Fermer</Button>
            )}
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </div>
  );
}
