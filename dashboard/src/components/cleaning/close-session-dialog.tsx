'use client';

import { useState } from 'react';
import type { CleaningSession } from '@/types/cleaning';
import { formatDuration, STUDIO_TYPE_LABELS } from '@/types/cleaning';

interface CloseSessionDialogProps {
  session: CleaningSession;
  isOpen: boolean;
  isClosing: boolean;
  onClose: () => void;
  onConfirm: (sessionId: string) => void;
}

export function CloseSessionDialog({
  session,
  isOpen,
  isClosing,
  onClose,
  onConfirm,
}: CloseSessionDialogProps) {
  if (!isOpen) return null;

  const currentDuration = session.startedAt
    ? (Date.now() - session.startedAt.getTime()) / 60000
    : 0;

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/50">
      <div className="mx-4 w-full max-w-md rounded-lg bg-white p-6 shadow-xl">
        <h2 className="text-lg font-semibold text-slate-900">
          Close Session
        </h2>
        <p className="mt-2 text-sm text-slate-600">
          Are you sure you want to manually close this cleaning session?
        </p>

        {/* Session details */}
        <div className="mt-4 rounded-lg bg-slate-50 p-3">
          <div className="flex justify-between text-sm">
            <span className="text-slate-500">Employee</span>
            <span className="font-medium text-slate-900">
              {session.employeeName}
            </span>
          </div>
          <div className="mt-1 flex justify-between text-sm">
            <span className="text-slate-500">Studio</span>
            <span className="font-medium text-slate-900">
              {session.studioNumber} — {session.buildingName}
            </span>
          </div>
          <div className="mt-1 flex justify-between text-sm">
            <span className="text-slate-500">Type</span>
            <span className="text-slate-700">
              {STUDIO_TYPE_LABELS[session.studioType]}
            </span>
          </div>
          <div className="mt-1 flex justify-between text-sm">
            <span className="text-slate-500">Duration so far</span>
            <span className="font-medium text-slate-900">
              {formatDuration(currentDuration)}
            </span>
          </div>
        </div>

        <div className="mt-4 text-xs text-slate-500">
          This session will be marked as &quot;Manually Closed&quot;.
        </div>

        {/* Actions */}
        <div className="mt-6 flex justify-end gap-3">
          <button
            onClick={onClose}
            disabled={isClosing}
            className="rounded-md border border-slate-300 px-4 py-2 text-sm font-medium text-slate-700 hover:bg-slate-50 disabled:opacity-50"
          >
            Cancel
          </button>
          <button
            onClick={() => onConfirm(session.id)}
            disabled={isClosing}
            className="rounded-md bg-red-600 px-4 py-2 text-sm font-medium text-white hover:bg-red-700 disabled:opacity-50"
          >
            {isClosing ? 'Closing...' : 'Close Session'}
          </button>
        </div>
      </div>
    </div>
  );
}
