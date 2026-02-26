'use client';

import { useState, useCallback } from 'react';
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card';
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
import { RefreshCw, CheckCircle, AlertTriangle, XCircle, Loader2, Car } from 'lucide-react';
import { supabaseClient } from '@/lib/supabase/client';

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
  const [isProcessing, setIsProcessing] = useState(false);
  const [showDialog, setShowDialog] = useState(false);
  const [dialogMode, setDialogMode] = useState<'failed' | 'all'>('failed');
  const [result, setResult] = useState<BatchResponse | null>(null);
  const [error, setError] = useState<string | null>(null);

  const handleReprocess = useCallback(
    async (mode: 'failed' | 'all') => {
      setIsProcessing(true);
      setError(null);
      setResult(null);

      try {
        const body =
          mode === 'failed'
            ? { reprocess_failed: true, limit: 500 }
            : { reprocess_all: true, limit: 500 };

        // Get current session for auth
        const { data: { session } } = await supabaseClient.auth.getSession();
        const token = session?.access_token;

        if (!token) {
          setError('Not authenticated. Please sign in again.');
          return;
        }

        // Call Edge Function via fetch for better error handling
        const supabaseUrl = process.env.NEXT_PUBLIC_SUPABASE_URL!.trim();
        const anonKey = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!.trim();

        const res = await fetch(`${supabaseUrl}/functions/v1/batch-match-trips`, {
          method: 'POST',
          headers: {
            'Content-Type': 'application/json',
            'Authorization': `Bearer ${token}`,
            'apikey': anonKey,
          },
          body: JSON.stringify(body),
        });

        if (!res.ok) {
          const errorText = await res.text();
          setError(`HTTP ${res.status}: ${errorText}`);
          return;
        }

        const response = await res.json() as BatchResponse;
        if (!response.success && response.error) {
          setError(response.error);
          return;
        }

        setResult(response);
      } catch (err) {
        setError(err instanceof Error ? err.message : 'An unexpected error occurred');
      } finally {
        setIsProcessing(false);
      }
    },
    []
  );

  const openDialog = useCallback((mode: 'failed' | 'all') => {
    setDialogMode(mode);
    setResult(null);
    setError(null);
    setShowDialog(true);
  }, []);

  const startProcessing = useCallback(() => {
    handleReprocess(dialogMode);
  }, [dialogMode, handleReprocess]);

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-bold tracking-tight">Mileage</h1>
        <p className="text-muted-foreground">
          Manage trip route matching and mileage tracking
        </p>
      </div>

      <Card>
        <CardHeader>
          <CardTitle className="flex items-center gap-2">
            <Car className="h-5 w-5" />
            Route Matching
          </CardTitle>
          <CardDescription>
            Match GPS trip traces to actual road routes using OSRM for accurate mileage calculation.
            Trips are automatically matched after shift completion, but you can re-process
            failed or all trips here.
          </CardDescription>
        </CardHeader>
        <CardContent className="space-y-4">
          <div className="flex flex-wrap gap-3">
            <Button
              variant="outline"
              onClick={() => openDialog('failed')}
              disabled={isProcessing}
            >
              <RefreshCw className="h-4 w-4 mr-2" />
              Re-process Failed Trips
            </Button>
            <Button
              variant="outline"
              onClick={() => openDialog('all')}
              disabled={isProcessing}
            >
              <RefreshCw className="h-4 w-4 mr-2" />
              Re-process All Trips
            </Button>
          </div>
        </CardContent>
      </Card>

      <Dialog open={showDialog} onOpenChange={setShowDialog}>
        <DialogContent className="sm:max-w-[480px]">
          <DialogHeader>
            <DialogTitle>
              {dialogMode === 'failed'
                ? 'Re-process Failed Trips'
                : 'Re-process All Trips'}
            </DialogTitle>
            <DialogDescription>
              {dialogMode === 'failed'
                ? 'This will re-attempt route matching for all pending and failed trips (up to 500).'
                : 'This will re-process ALL trips, including already matched ones (up to 500). Existing matches will be overwritten.'}
            </DialogDescription>
          </DialogHeader>

          {error && (
            <div className="rounded-md bg-red-50 p-3 text-sm text-red-700">
              {error}
            </div>
          )}

          {isProcessing && (
            <div className="flex items-center justify-center py-8">
              <div className="text-center space-y-3">
                <Loader2 className="h-8 w-8 animate-spin mx-auto text-blue-500" />
                <p className="text-sm text-muted-foreground">
                  Processing trips... This may take a few minutes.
                </p>
              </div>
            </div>
          )}

          {result && result.summary && (
            <div className="space-y-4">
              <div className="grid grid-cols-2 gap-3">
                <div className="rounded-lg border p-3 text-center">
                  <p className="text-2xl font-bold">{result.summary.total_requested}</p>
                  <p className="text-xs text-muted-foreground">Total Trips</p>
                </div>
                <div className="rounded-lg border p-3 text-center">
                  <p className="text-2xl font-bold">{result.summary.duration_seconds}s</p>
                  <p className="text-xs text-muted-foreground">Duration</p>
                </div>
              </div>

              <div className="flex flex-wrap gap-2">
                <Badge className="bg-green-100 text-green-700 hover:bg-green-100">
                  <CheckCircle className="h-3 w-3 mr-1" />
                  {result.summary.matched} matched
                </Badge>
                <Badge className="bg-gray-100 text-gray-600 hover:bg-gray-100">
                  {result.summary.skipped} skipped
                </Badge>
                <Badge className="bg-red-100 text-red-700 hover:bg-red-100">
                  <XCircle className="h-3 w-3 mr-1" />
                  {result.summary.failed} failed
                </Badge>
                {result.summary.anomalous > 0 && (
                  <Badge className="bg-yellow-100 text-yellow-700 hover:bg-yellow-100">
                    <AlertTriangle className="h-3 w-3 mr-1" />
                    {result.summary.anomalous} anomalous
                  </Badge>
                )}
              </div>

              {result.summary.total_requested === 0 && (
                <p className="text-sm text-muted-foreground text-center py-2">
                  No trips found to process.
                </p>
              )}
            </div>
          )}

          <DialogFooter>
            {!result ? (
              <>
                <Button variant="outline" onClick={() => setShowDialog(false)}>
                  Cancel
                </Button>
                <Button onClick={startProcessing} disabled={isProcessing}>
                  {isProcessing ? (
                    <>
                      <Loader2 className="h-4 w-4 mr-2 animate-spin" />
                      Processing...
                    </>
                  ) : (
                    'Start Processing'
                  )}
                </Button>
              </>
            ) : (
              <Button onClick={() => setShowDialog(false)}>Close</Button>
            )}
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </div>
  );
}
