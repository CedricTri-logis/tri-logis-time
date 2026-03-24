"use client";

import { useState } from "react";
import { Button } from "@/components/ui/button";
import {
  Popover,
  PopoverContent,
  PopoverTrigger,
} from "@/components/ui/popover";
import { Textarea } from "@/components/ui/textarea";
import { Pencil } from "lucide-react";
import { createClient } from "@/lib/supabase/client";

interface ClockTimeEditPopoverProps {
  shiftId: string;
  field: "clocked_in_at" | "clocked_out_at";
  currentTime: string; // ISO string
  originalTime?: string; // ISO string, if already edited
  isEdited: boolean;
  onUpdated: (newDetail: any) => void;
  effectiveClockIn?: string;  // current effective clock-in ISO
  effectiveClockOut?: string; // current effective clock-out ISO
}

export function ClockTimeEditPopover({
  shiftId,
  field,
  currentTime,
  originalTime,
  isEdited,
  onUpdated,
  effectiveClockIn,
  effectiveClockOut,
}: ClockTimeEditPopoverProps) {
  const [open, setOpen] = useState(false);
  const [time, setTime] = useState(() => {
    const d = new Date(currentTime);
    return `${String(d.getHours()).padStart(2, "0")}:${String(d.getMinutes()).padStart(2, "0")}`;
  });
  const [reason, setReason] = useState("");
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const addsTime = (() => {
    if (!time) return false;
    const [h, m] = time.split(':').map(Number);
    const currentDate = new Date(currentTime);
    const newDate = new Date(currentDate);
    newDate.setHours(h, m, 0, 0);

    if (field === 'clocked_out_at') {
      const currentEffective = new Date(effectiveClockOut || currentTime);
      return newDate > currentEffective;
    } else {
      const currentEffective = new Date(effectiveClockIn || currentTime);
      return newDate < currentEffective;
    }
  })();

  const addedMinutes = (() => {
    if (!addsTime) return 0;
    const [h, m] = time.split(':').map(Number);
    const currentDate = new Date(currentTime);
    const newDate = new Date(currentDate);
    newDate.setHours(h, m, 0, 0);
    const effective = new Date(field === 'clocked_out_at' ? (effectiveClockOut || currentTime) : (effectiveClockIn || currentTime));
    return Math.abs(Math.round((newDate.getTime() - effective.getTime()) / 60000));
  })();

  const handleSave = async () => {
    setLoading(true);
    setError(null);

    // Build new timestamp: same date, new time
    const currentDate = new Date(currentTime);
    const [hours, minutes] = time.split(":").map(Number);
    const newDate = new Date(currentDate);
    newDate.setHours(hours, minutes, 0, 0);

    const supabase = createClient();
    const { data, error: rpcError } = await supabase.rpc("edit_shift_time", {
      p_shift_id: shiftId,
      p_field: field,
      p_new_value: newDate.toISOString(),
      p_reason: reason || null,
    });

    if (rpcError) {
      setError(rpcError.message);
      setLoading(false);
      return;
    }

    setLoading(false);
    setOpen(false);
    setReason("");
    onUpdated(data);
  };

  return (
    <Popover open={open} onOpenChange={setOpen}>
      <PopoverTrigger asChild>
        <Button variant="ghost" size="icon" className="h-6 w-6 ml-1">
          <Pencil className="h-3 w-3" />
        </Button>
      </PopoverTrigger>
      <PopoverContent className="w-64 p-3" align="start">
        <div className="space-y-3">
          <div className="text-sm font-medium">
            {field === "clocked_in_at" ? "Modifier pointage entrée" : "Modifier pointage sortie"}
          </div>

          <div>
            <label className="text-xs text-muted-foreground">Heure</label>
            <input
              type="time"
              value={time}
              onChange={(e) => setTime(e.target.value)}
              className="w-full rounded-md border px-3 py-1.5 text-sm"
            />
          </div>

          {addsTime && addedMinutes > 0 && (
            <div className="bg-amber-50 border border-amber-200 rounded-md px-3 py-2 text-xs text-amber-800 flex items-center gap-1.5">
              <strong>+{addedMinutes} min</strong> seront ajoutées comme « Temps manuel »
            </div>
          )}

          <div>
            <label className="text-xs text-muted-foreground">
              Raison {addsTime ? <span className="text-destructive">*</span> : '(optionnel)'}
            </label>
            <Textarea
              value={reason}
              onChange={(e) => setReason(e.target.value)}
              placeholder="ex: Employé a oublié de pointer"
              className="h-16 text-sm"
            />
          </div>

          {error && (
            <div className="text-xs text-destructive">{error}</div>
          )}

          <div className="flex gap-2 justify-end">
            <Button
              variant="outline"
              size="sm"
              onClick={() => setOpen(false)}
              disabled={loading}
            >
              Annuler
            </Button>
            <Button
              size="sm"
              onClick={handleSave}
              disabled={loading || (addsTime && !reason.trim())}
            >
              {loading ? "Enregistrement..." : "Enregistrer"}
            </Button>
          </div>
        </div>
      </PopoverContent>
    </Popover>
  );
}
