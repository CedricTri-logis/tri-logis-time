"use client";

import { useState, useMemo } from "react";
import { Button } from "@/components/ui/button";
import {
  Popover,
  PopoverContent,
  PopoverTrigger,
} from "@/components/ui/popover";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";
import { MoreVertical, Scissors, X, Undo2 } from "lucide-react";
import { workforceClient } from "@/lib/supabase/client";
import { formatTime } from "@/lib/utils/activity-display";

interface ActivitySegmentModalProps {
  activityType: 'stop' | 'trip' | 'gap' | 'lunch';
  activityId: string;
  startedAt: string;
  endedAt: string;
  isSegmented: boolean;
  employeeId?: string;  // required for gaps
  onUpdated: (newDetail: any) => void;
}

const TITLE_MAP: Record<ActivitySegmentModalProps['activityType'], string> = {
  stop: "Diviser l'arrêt",
  trip: "Diviser le trajet",
  gap: "Diviser le temps non suivi",
  lunch: "Diviser la pause dîner",
};

export function ActivitySegmentModal({
  activityType,
  activityId,
  startedAt,
  endedAt,
  isSegmented,
  employeeId,
  onUpdated,
}: ActivitySegmentModalProps) {
  const [open, setOpen] = useState(false);
  const [cutPoints, setCutPoints] = useState<string[]>([]);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const startTime = new Date(startedAt);
  const endTime = new Date(endedAt);

  const title = TITLE_MAP[activityType];

  const addCutPoint = () => {
    const midpoint = new Date((startTime.getTime() + endTime.getTime()) / 2);
    const timeStr = `${String(midpoint.getHours()).padStart(2, "0")}:${String(midpoint.getMinutes()).padStart(2, "0")}`;
    setCutPoints((prev) => [...prev, timeStr]);
  };

  const removeCutPoint = (index: number) => {
    setCutPoints((prev) => prev.filter((_, i) => i !== index));
  };

  const updateCutPoint = (index: number, value: string) => {
    setCutPoints((prev) => prev.map((cp, i) => (i === index ? value : cp)));
  };

  const segments = useMemo(() => {
    if (cutPoints.length === 0) return [];

    const cutTimestamps = cutPoints
      .map((cp) => {
        const [h, m] = cp.split(":").map(Number);
        const d = new Date(startedAt);
        d.setHours(h, m, 0, 0);
        return d;
      })
      .sort((a, b) => a.getTime() - b.getTime());

    const result: { start: Date; end: Date; minutes: number }[] = [];
    let segStart = startTime;

    for (const cp of cutTimestamps) {
      result.push({
        start: segStart,
        end: cp,
        minutes: Math.round((cp.getTime() - segStart.getTime()) / 60000),
      });
      segStart = cp;
    }
    result.push({
      start: segStart,
      end: endTime,
      minutes: Math.round((endTime.getTime() - segStart.getTime()) / 60000),
    });

    return result;
  }, [cutPoints, startedAt, endedAt]);

  const handleApply = async () => {
    setLoading(true);
    setError(null);

    const cutTimestamps = cutPoints
      .map((cp) => {
        const [h, m] = cp.split(":").map(Number);
        const d = new Date(startedAt);
        d.setHours(h, m, 0, 0);
        return d.toISOString();
      })
      .sort();

    const supabase = workforceClient();
    const { data, error: rpcError } = await supabase.rpc("segment_activity", {
      p_activity_type: activityType,
      p_activity_id: activityId,
      p_cut_points: cutTimestamps,
      ...(activityType === 'gap' ? {
        p_employee_id: employeeId,
        p_starts_at: startedAt,
        p_ends_at: endedAt,
      } : {}),
    });

    if (rpcError) {
      setError(rpcError.message);
      setLoading(false);
      return;
    }

    setLoading(false);
    setOpen(false);
    setCutPoints([]);
    onUpdated(data);
  };

  const handleUnsegment = async () => {
    setLoading(true);
    setError(null);

    const supabase = workforceClient();
    const { data, error: rpcError } = await supabase.rpc("unsegment_activity", {
      p_activity_type: activityType,
      p_activity_id: activityId,
    });

    if (rpcError) {
      setError(rpcError.message);
      setLoading(false);
      return;
    }

    setLoading(false);
    setOpen(false);
    onUpdated(data);
  };

  return (
    <>
      <DropdownMenu>
        <DropdownMenuTrigger asChild>
          <Button variant="ghost" size="icon" className="h-7 w-7" disabled={loading}>
            <MoreVertical className="h-4 w-4 text-muted-foreground" />
          </Button>
        </DropdownMenuTrigger>
        <DropdownMenuContent align="end">
          {!isSegmented && (
            <DropdownMenuItem onSelect={() => setOpen(true)}>
              <Scissors className="h-3.5 w-3.5 mr-2" />
              {title}
            </DropdownMenuItem>
          )}
          {isSegmented && (
            <DropdownMenuItem
              onSelect={() => {
                if (window.confirm("Retirer la segmentation? Les approbations par segment seront supprimées.")) {
                  handleUnsegment();
                }
              }}
            >
              <Undo2 className="h-3.5 w-3.5 mr-2" />
              Retirer la division
            </DropdownMenuItem>
          )}
        </DropdownMenuContent>
      </DropdownMenu>

      <Popover open={open} onOpenChange={setOpen}>
        <PopoverTrigger asChild>
          <span />
        </PopoverTrigger>
      <PopoverContent className="w-80 p-3" align="start">
        <div className="space-y-3">
          <div className="text-sm font-medium">
            {title} ({formatTime(startedAt)} — {formatTime(endedAt)})
          </div>

          {/* Visual bar */}
          <div className="relative h-3 bg-muted rounded-full">
            <div className="absolute inset-0 bg-primary/20 rounded-full" />
            {segments.length > 0 &&
              segments.map((seg, i) => {
                const totalMs = endTime.getTime() - startTime.getTime();
                const leftPct = ((seg.start.getTime() - startTime.getTime()) / totalMs) * 100;
                const widthPct = ((seg.end.getTime() - seg.start.getTime()) / totalMs) * 100;
                return (
                  <div
                    key={i}
                    className="absolute h-full rounded-full border-r-2 border-background"
                    style={{
                      left: `${leftPct}%`,
                      width: `${widthPct}%`,
                      backgroundColor: `hsl(${(i * 60 + 200) % 360}, 50%, 60%)`,
                    }}
                  />
                );
              })}
          </div>

          {/* Cut points */}
          <div className="space-y-2">
            {cutPoints.map((cp, i) => (
              <div key={i} className="flex items-center gap-2">
                <span className="text-xs text-muted-foreground w-12">Coupe {i + 1}</span>
                <input
                  type="time"
                  value={cp}
                  onChange={(e) => updateCutPoint(i, e.target.value)}
                  className="flex-1 rounded-md border px-2 py-1 text-sm"
                />
                <Button
                  variant="ghost"
                  size="icon"
                  className="h-6 w-6"
                  onClick={() => removeCutPoint(i)}
                >
                  <X className="h-3 w-3" />
                </Button>
              </div>
            ))}
          </div>

          <Button variant="outline" size="sm" onClick={addCutPoint} className="w-full">
            + Ajouter un point de coupe
          </Button>

          {/* Segment preview */}
          {segments.length > 0 && (
            <div className="space-y-1 text-xs">
              <div className="text-muted-foreground font-medium">Aperçu:</div>
              {segments.map((seg, i) => (
                <div key={i} className="flex justify-between">
                  <span>
                    Segment {i + 1}/{segments.length}
                  </span>
                  <span>
                    {formatTime(seg.start.toISOString())} — {formatTime(seg.end.toISOString())} ({seg.minutes} min)
                  </span>
                </div>
              ))}
            </div>
          )}

          {error && <div className="text-xs text-destructive">{error}</div>}

          <div className="flex gap-2 justify-end">
            <Button variant="outline" size="sm" onClick={() => setOpen(false)} disabled={loading}>
              Annuler
            </Button>
            <Button size="sm" onClick={handleApply} disabled={loading || cutPoints.length === 0}>
              {loading ? "Application..." : "Appliquer"}
            </Button>
          </div>
        </div>
      </PopoverContent>
    </Popover>
    </>
  );
}
