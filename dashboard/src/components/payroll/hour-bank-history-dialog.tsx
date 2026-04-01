'use client';

import { useEffect, useState, useCallback, useMemo } from 'react';
import { format, parseISO } from 'date-fns';
import { fr } from 'date-fns/locale';
import { workforceClient } from '@/lib/supabase/client';
import { toast } from 'sonner';
import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
  DialogDescription,
} from '@/components/ui/dialog';
import { Button } from '@/components/ui/button';
import { Badge } from '@/components/ui/badge';
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from '@/components/ui/table';
import {
  Tooltip,
  TooltipContent,
  TooltipProvider,
  TooltipTrigger,
} from '@/components/ui/tooltip';
import { Trash2, Loader2, Inbox } from 'lucide-react';
import type { HourBankTransaction } from '@/types/payroll';

// ─── Props ──────────────────────────────────────────────────────────────────

interface HourBankHistoryDialogProps {
  open: boolean;
  onClose: () => void;
  employeeId: string;
  employeeName: string;
  onDelete: () => void; // triggers refetch after deletion
}

// ─── Helpers ────────────────────────────────────────────────────────────────

/** Format money as "$1 234.56" */
function fmtMoney(n: number): string {
  const formatted = Math.abs(n)
    .toFixed(2)
    .replace(/\B(?=(\d{3})+(?!\d))/g, ' ');
  return n < 0 ? `-${formatted} $` : `${formatted} $`;
}

/** Format hours as "Xh00" */
function fmtHours(hours: number): string {
  const h = Math.floor(Math.abs(hours));
  const m = Math.round((Math.abs(hours) - h) * 60);
  return `${h}h${m.toString().padStart(2, '0')}`;
}

/** Format a date string as "22 mars 2026" */
function fmtDate(dateStr: string): string {
  return format(parseISO(dateStr), 'd MMMM yyyy', { locale: fr });
}

/** Format a date string short as "22 mars" */
function fmtDateShort(dateStr: string): string {
  return format(parseISO(dateStr), 'd MMM', { locale: fr });
}

/** Format a period range as "22 mars - 5 avr." */
function fmtPeriod(start: string, end: string): string {
  return `${fmtDateShort(start)} \u2013 ${fmtDateShort(end)}`;
}

// ─── Type badge config ──────────────────────────────────────────────────────

const TYPE_CONFIG: Record<
  HourBankTransaction['type'],
  { label: string; badgeClass: string; amountClass: string }
> = {
  deposit: {
    label: 'Depot banque',
    badgeClass: 'bg-blue-100 text-blue-700 border-blue-200',
    amountClass: 'text-blue-600',
  },
  withdrawal: {
    label: 'Retrait banque',
    badgeClass: 'bg-green-100 text-green-700 border-green-200',
    amountClass: 'text-green-600',
  },
  sick_leave: {
    label: 'Maladie',
    badgeClass: 'bg-red-100 text-red-700 border-red-200',
    amountClass: 'text-red-600',
  },
};

// ─── Main Component ─────────────────────────────────────────────────────────

export function HourBankHistoryDialog({
  open,
  onClose,
  employeeId,
  employeeName,
  onDelete,
}: HourBankHistoryDialogProps) {
  const [transactions, setTransactions] = useState<HourBankTransaction[]>([]);
  const [loading, setLoading] = useState(false);
  const [deletingId, setDeletingId] = useState<string | null>(null);

  const supabase = workforceClient();

  const fetchHistory = useCallback(async () => {
    setLoading(true);
    try {
      const { data, error } = await supabase.rpc('get_hour_bank_history', {
        p_employee_id: employeeId,
      });
      if (error) {
        toast.error(error.message);
        return;
      }
      setTransactions((data as unknown as HourBankTransaction[]) ?? []);
    } finally {
      setLoading(false);
    }
  }, [employeeId, supabase]);

  // Fetch when dialog opens
  useEffect(() => {
    if (open) {
      fetchHistory();
    } else {
      setTransactions([]);
    }
  }, [open, fetchHistory]);

  // ── Delete handler ──
  const handleDelete = async (txn: HourBankTransaction) => {
    setDeletingId(txn.transaction_id);
    try {
      const rpcName =
        txn.type === 'sick_leave'
          ? 'delete_sick_leave_usage'
          : 'delete_hour_bank_transaction';
      const paramName =
        txn.type === 'sick_leave' ? 'p_usage_id' : 'p_transaction_id';

      const { error } = await supabase.rpc(rpcName, {
        [paramName]: txn.transaction_id,
      });

      if (error) {
        toast.error(error.message);
        return;
      }

      fetchHistory(); // refresh list
      onDelete(); // trigger parent refetch
    } finally {
      setDeletingId(null);
    }
  };

  // ── Computed summaries ──
  const summary = useMemo(() => {
    let totalDeposited = 0;
    let totalWithdrawn = 0;
    let sickHoursUsed = 0;

    for (const txn of transactions) {
      if (txn.type === 'deposit') totalDeposited += txn.amount;
      else if (txn.type === 'withdrawal') totalWithdrawn += txn.amount;
      else if (txn.type === 'sick_leave') sickHoursUsed += txn.hours;
    }

    return {
      totalDeposited,
      totalWithdrawn,
      sickHoursUsed,
      bankBalance: totalDeposited - totalWithdrawn,
    };
  }, [transactions]);

  return (
    <Dialog
      open={open}
      onOpenChange={(isOpen) => {
        if (!isOpen) onClose();
      }}
    >
      <DialogContent className="sm:max-w-4xl max-h-[90vh] overflow-y-auto">
        <DialogHeader>
          <DialogTitle>Historique &mdash; {employeeName}</DialogTitle>
          <DialogDescription className="flex flex-wrap gap-2 pt-1">
            <Badge
              variant="outline"
              className="bg-blue-50 text-blue-700 border-blue-200"
            >
              Banque: {fmtMoney(summary.bankBalance)} ({fmtHours(
                transactions
                  .filter((t) => t.type === 'deposit')
                  .reduce((acc, t) => acc + t.hours, 0) -
                  transactions
                    .filter((t) => t.type === 'withdrawal')
                    .reduce((acc, t) => acc + t.hours, 0),
              )})
            </Badge>
            <Badge
              variant="outline"
              className="bg-red-50 text-red-700 border-red-200"
            >
              Maladie: {fmtHours(summary.sickHoursUsed)} utilisees
            </Badge>
          </DialogDescription>
        </DialogHeader>

        {loading ? (
          <div className="flex items-center justify-center py-12">
            <Loader2 className="h-6 w-6 animate-spin text-muted-foreground" />
          </div>
        ) : transactions.length === 0 ? (
          <div className="flex flex-col items-center justify-center py-12 text-muted-foreground">
            <Inbox className="h-10 w-10 mb-2" />
            <p className="text-sm">Aucune transaction</p>
          </div>
        ) : (
          <>
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead>Date</TableHead>
                  <TableHead>Type</TableHead>
                  <TableHead className="text-right">Heures</TableHead>
                  <TableHead className="text-right">Taux</TableHead>
                  <TableHead className="text-right">Valeur</TableHead>
                  <TableHead>Periode</TableHead>
                  <TableHead>Raison</TableHead>
                  <TableHead>Par</TableHead>
                  <TableHead className="w-10" />
                </TableRow>
              </TableHeader>
              <TableBody>
                {transactions.map((txn) => {
                  const config = TYPE_CONFIG[txn.type];
                  const isDeleting = deletingId === txn.transaction_id;

                  return (
                    <TableRow key={txn.transaction_id}>
                      <TableCell className="text-xs">
                        {fmtDate(txn.created_at)}
                      </TableCell>
                      <TableCell>
                        <Badge
                          variant="outline"
                          className={config.badgeClass}
                        >
                          {config.label}
                        </Badge>
                      </TableCell>
                      <TableCell
                        className={`text-right font-mono text-xs ${config.amountClass}`}
                      >
                        {fmtHours(txn.hours)}
                      </TableCell>
                      <TableCell className="text-right font-mono text-xs">
                        {txn.hourly_rate > 0
                          ? `${txn.hourly_rate.toFixed(2)} $`
                          : '\u2014'}
                      </TableCell>
                      <TableCell
                        className={`text-right font-mono text-xs ${config.amountClass}`}
                      >
                        {fmtMoney(txn.amount)}
                      </TableCell>
                      <TableCell className="text-xs text-muted-foreground">
                        {fmtPeriod(txn.period_start, txn.period_end)}
                      </TableCell>
                      <TableCell className="text-xs max-w-[160px] truncate">
                        {txn.reason || '\u2014'}
                      </TableCell>
                      <TableCell className="text-xs text-muted-foreground">
                        {txn.created_by_name || '\u2014'}
                      </TableCell>
                      <TableCell>
                        {txn.can_delete ? (
                          <Button
                            variant="ghost"
                            size="icon"
                            className="h-7 w-7 text-muted-foreground hover:text-destructive"
                            onClick={() => handleDelete(txn)}
                            disabled={isDeleting}
                          >
                            {isDeleting ? (
                              <Loader2 className="h-3.5 w-3.5 animate-spin" />
                            ) : (
                              <Trash2 className="h-3.5 w-3.5" />
                            )}
                          </Button>
                        ) : (
                          <TooltipProvider>
                            <Tooltip>
                              <TooltipTrigger asChild>
                                <span className="inline-flex">
                                  <Button
                                    variant="ghost"
                                    size="icon"
                                    className="h-7 w-7 text-muted-foreground/40"
                                    disabled
                                  >
                                    <Trash2 className="h-3.5 w-3.5" />
                                  </Button>
                                </span>
                              </TooltipTrigger>
                              <TooltipContent>
                                Paie verrouillee
                              </TooltipContent>
                            </Tooltip>
                          </TooltipProvider>
                        )}
                      </TableCell>
                    </TableRow>
                  );
                })}
              </TableBody>
            </Table>

            {/* ── Summary footer ── */}
            <div className="flex flex-wrap items-center gap-x-6 gap-y-1 border-t pt-3 text-xs text-muted-foreground">
              <span>
                Total depose:{' '}
                <span className="font-mono font-medium text-blue-600">
                  {fmtMoney(summary.totalDeposited)}
                </span>
              </span>
              <span>
                Total retire:{' '}
                <span className="font-mono font-medium text-green-600">
                  {fmtMoney(summary.totalWithdrawn)}
                </span>
              </span>
              <span>
                Maladie utilisee:{' '}
                <span className="font-mono font-medium text-red-600">
                  {fmtHours(summary.sickHoursUsed)}
                </span>
              </span>
              <span className="ml-auto font-medium text-foreground">
                Solde banque:{' '}
                <span className="font-mono text-blue-600">
                  {fmtMoney(summary.bankBalance)}
                </span>
              </span>
            </div>
          </>
        )}
      </DialogContent>
    </Dialog>
  );
}
