'use client';

import { Calendar } from 'lucide-react';
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from '@/components/ui/select';
import type { DateRange, DateRangePreset } from '@/types/dashboard';

interface DateRangeSelectorProps {
  value: DateRange;
  onChange: (range: DateRange) => void;
}

const presets: { value: DateRangePreset; label: string }[] = [
  { value: 'today', label: 'Today' },
  { value: 'this_week', label: 'This Week' },
  { value: 'this_month', label: 'This Month' },
];

export function DateRangeSelector({ value, onChange }: DateRangeSelectorProps) {
  return (
    <div className="flex items-center gap-2">
      <Calendar className="h-4 w-4 text-slate-500" />
      <Select
        value={value.preset}
        onValueChange={(preset: DateRangePreset) => onChange({ preset })}
      >
        <SelectTrigger className="w-[140px]">
          <SelectValue placeholder="Select period" />
        </SelectTrigger>
        <SelectContent>
          {presets.map((preset) => (
            <SelectItem key={preset.value} value={preset.value}>
              {preset.label}
            </SelectItem>
          ))}
        </SelectContent>
      </Select>
    </div>
  );
}
