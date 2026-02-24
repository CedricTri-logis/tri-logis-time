'use client';

import { useState, useCallback, useRef, useEffect, useMemo } from 'react';
import type { HistoricalGpsPoint, PlaybackSpeed, PlaybackState } from '@/types/history';

// Default interval between points during playback (ms)
const DEFAULT_INTERVAL_MS = 1000;
// Gap threshold for skipping (5 minutes)
const LARGE_GAP_THRESHOLD_MS = 5 * 60 * 1000;

interface UsePlaybackAnimationReturn {
  /** Current playback state */
  state: PlaybackState;
  /** Current point being displayed */
  currentPoint: HistoricalGpsPoint | null;
  /** Progress percentage (0-1) */
  progress: number;
  /** Whether there's a large time gap at current position */
  hasLargeGap: boolean;
  /** Start or resume playback */
  play: () => void;
  /** Pause playback */
  pause: () => void;
  /** Seek to a specific index */
  seek: (index: number) => void;
  /** Set playback speed */
  setSpeed: (speed: PlaybackSpeed) => void;
  /** Reset to beginning */
  reset: () => void;
}

/**
 * Hook for managing GPS trail playback animation.
 * Uses requestAnimationFrame for smooth animation.
 */
export function usePlaybackAnimation(
  trail: HistoricalGpsPoint[]
): UsePlaybackAnimationReturn {
  // Calculate total duration from trail timestamps
  const totalDurationMs = useMemo(() => {
    if (trail.length < 2) return 0;
    const first = trail[0].capturedAt.getTime();
    const last = trail[trail.length - 1].capturedAt.getTime();
    return last - first;
  }, [trail]);

  const [state, setState] = useState<PlaybackState>({
    isPlaying: false,
    currentIndex: 0,
    speedMultiplier: 1,
    elapsedMs: 0,
    totalDurationMs,
  });

  // Animation frame reference
  const animationFrameRef = useRef<number | null>(null);
  const lastTimestampRef = useRef<number>(0);

  // Calculate time intervals between points
  const intervals = useMemo(() => {
    if (trail.length < 2) return [];
    const result: number[] = [];
    for (let i = 1; i < trail.length; i++) {
      const interval =
        trail[i].capturedAt.getTime() - trail[i - 1].capturedAt.getTime();
      result.push(interval);
    }
    return result;
  }, [trail]);

  // Calculate cumulative time for seeking
  const cumulativeTimes = useMemo(() => {
    const result: number[] = [0];
    for (const interval of intervals) {
      result.push(result[result.length - 1] + interval);
    }
    return result;
  }, [intervals]);

  // Current point
  const currentPoint = trail.length > 0 ? trail[state.currentIndex] : null;

  // Progress (0-1)
  const progress =
    totalDurationMs > 0 ? state.elapsedMs / totalDurationMs : 0;

  // Check for large gap at current position
  const hasLargeGap = useMemo(() => {
    if (state.currentIndex >= intervals.length) return false;
    return intervals[state.currentIndex] > LARGE_GAP_THRESHOLD_MS;
  }, [intervals, state.currentIndex]);

  // Animation loop
  const animate = useCallback(
    (timestamp: number) => {
      if (!lastTimestampRef.current) {
        lastTimestampRef.current = timestamp;
      }

      const deltaMs = (timestamp - lastTimestampRef.current) * state.speedMultiplier;
      lastTimestampRef.current = timestamp;

      setState((prev) => {
        // Calculate new elapsed time
        let newElapsedMs = prev.elapsedMs + deltaMs;

        // Find the new index based on elapsed time
        let newIndex = prev.currentIndex;
        while (
          newIndex < cumulativeTimes.length - 1 &&
          newElapsedMs >= cumulativeTimes[newIndex + 1]
        ) {
          newIndex++;
        }

        // Check if we've reached the end
        if (newIndex >= trail.length - 1) {
          return {
            ...prev,
            isPlaying: false,
            currentIndex: trail.length - 1,
            elapsedMs: totalDurationMs,
          };
        }

        return {
          ...prev,
          currentIndex: newIndex,
          elapsedMs: newElapsedMs,
        };
      });

      // Continue animation if still playing
      animationFrameRef.current = requestAnimationFrame(animate);
    },
    [state.speedMultiplier, cumulativeTimes, trail.length, totalDurationMs]
  );

  // Start/stop animation based on isPlaying state
  useEffect(() => {
    if (state.isPlaying && trail.length > 1) {
      lastTimestampRef.current = 0;
      animationFrameRef.current = requestAnimationFrame(animate);
    }

    return () => {
      if (animationFrameRef.current) {
        cancelAnimationFrame(animationFrameRef.current);
        animationFrameRef.current = null;
      }
    };
  }, [state.isPlaying, animate, trail.length]);

  // Update total duration when trail changes
  useEffect(() => {
    setState((prev) => ({
      ...prev,
      totalDurationMs,
    }));
  }, [totalDurationMs]);

  // Play
  const play = useCallback(() => {
    if (trail.length < 2) return;

    setState((prev) => {
      // If at end, restart from beginning
      if (prev.currentIndex >= trail.length - 1) {
        return {
          ...prev,
          isPlaying: true,
          currentIndex: 0,
          elapsedMs: 0,
        };
      }
      return {
        ...prev,
        isPlaying: true,
      };
    });
  }, [trail.length]);

  // Pause
  const pause = useCallback(() => {
    setState((prev) => ({
      ...prev,
      isPlaying: false,
    }));
  }, []);

  // Seek
  const seek = useCallback(
    (index: number) => {
      if (index < 0 || index >= trail.length) return;

      setState((prev) => ({
        ...prev,
        currentIndex: index,
        elapsedMs: cumulativeTimes[index] ?? 0,
      }));
    },
    [trail.length, cumulativeTimes]
  );

  // Set speed
  const setSpeed = useCallback((speed: PlaybackSpeed) => {
    setState((prev) => ({
      ...prev,
      speedMultiplier: speed,
    }));
  }, []);

  // Reset
  const reset = useCallback(() => {
    setState({
      isPlaying: false,
      currentIndex: 0,
      speedMultiplier: 1,
      elapsedMs: 0,
      totalDurationMs,
    });
  }, [totalDurationMs]);

  return {
    state,
    currentPoint,
    progress,
    hasLargeGap,
    play,
    pause,
    seek,
    setSpeed,
    reset,
  };
}
