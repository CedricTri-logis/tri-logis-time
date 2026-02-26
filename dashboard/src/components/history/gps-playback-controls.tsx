'use client';

import { Play, Pause, RotateCcw, FastForward } from 'lucide-react';
import { Button } from '@/components/ui/button';
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from '@/components/ui/select';
import { Card, CardContent } from '@/components/ui/card';
import { PLAYBACK_SPEEDS, type PlaybackSpeed } from '@/types/history';

interface GpsPlaybackControlsProps {
  isPlaying: boolean;
  currentSpeed: PlaybackSpeed;
  onPlay: () => void;
  onPause: () => void;
  onReset: () => void;
  onSpeedChange: (speed: PlaybackSpeed) => void;
  disabled?: boolean;
}

/**
 * Playback control bar with play/pause, speed selector, and reset.
 */
export function GpsPlaybackControls({
  isPlaying,
  currentSpeed,
  onPlay,
  onPause,
  onReset,
  onSpeedChange,
  disabled = false,
}: GpsPlaybackControlsProps) {
  return (
    <Card>
      <CardContent className="py-3">
        <div className="flex items-center justify-center gap-4">
          {/* Reset button */}
          <Button
            variant="ghost"
            size="icon"
            onClick={onReset}
            disabled={disabled}
            title="Revenir au début"
          >
            <RotateCcw className="h-4 w-4" />
          </Button>

          {/* Play/Pause button */}
          <Button
            variant="default"
            size="lg"
            onClick={isPlaying ? onPause : onPlay}
            disabled={disabled}
            className="px-8"
          >
            {isPlaying ? (
              <>
                <Pause className="h-5 w-5 mr-2" />
                Pause
              </>
            ) : (
              <>
                <Play className="h-5 w-5 mr-2" />
                Lecture
              </>
            )}
          </Button>

          {/* Speed selector */}
          <div className="flex items-center gap-2">
            <FastForward className="h-4 w-4 text-slate-400" />
            <Select
              value={currentSpeed.toString()}
              onValueChange={(value) => onSpeedChange(parseFloat(value) as PlaybackSpeed)}
              disabled={disabled}
            >
              <SelectTrigger className="w-[120px]">
                <SelectValue />
              </SelectTrigger>
              <SelectContent>
                {PLAYBACK_SPEEDS.map((speed) => (
                  <SelectItem key={speed.value} value={speed.value.toString()}>
                    {speed.label}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          </div>
        </div>
      </CardContent>
    </Card>
  );
}
