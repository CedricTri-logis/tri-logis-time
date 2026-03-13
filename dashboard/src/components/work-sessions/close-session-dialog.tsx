'use client';

import type { WorkSession } from '@/types/work-session';
import {
  ACTIVITY_TYPE_CONFIG,
  formatWorkSessionDuration,
} from '@/types/work-session';

interface CloseSessionDialogProps {
  session: WorkSession;
  isOpen: boolean;
  isClosing: boolean;
  onClose: () => void;
  onConfirm: (sessionId: string, employeeId: string) => void;
}

function getLocationLabel(session: WorkSession): string {
  if (session.activityType === 'admin') return 'Administration';
  const parts: string[] = [];
  if (session.studioNumber) parts.push(session.studioNumber);
  if (session.buildingName) parts.push(session.buildingName);
  if (parts.length > 0) return parts.join(' \u2014 ');
  return '\u2014';
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

  const typeConfig = ACTIVITY_TYPE_CONFIG[session.activityType];

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/50">
      <div className="mx-4 w-full max-w-md rounded-lg bg-white p-6 shadow-xl">
        <h2 className="text-lg font-semibold text-slate-900">
          Fermer la session
        </h2>
        <p className="mt-2 text-sm text-slate-600">
          Voulez-vous vraiment fermer manuellement cette session de travail ?
        </p>

        {/* Session details */}
        <div className="mt-4 rounded-lg bg-slate-50 p-3">
          <div className="flex justify-between text-sm">
            <span className="text-slate-500">Employe</span>
            <span className="font-medium text-slate-900">
              {session.employeeName}
            </span>
          </div>
          <div className="mt-1 flex justify-between text-sm">
            <span className="text-slate-500">Type</span>
            <span
              className="inline-flex items-center gap-1.5 rounded-full px-2 py-0.5 text-xs font-medium"
              style={{
                backgroundColor: typeConfig.bgColor,
                color: typeConfig.color,
              }}
            >
              {typeConfig.label}
            </span>
          </div>
          <div className="mt-1 flex justify-between text-sm">
            <span className="text-slate-500">Lieu</span>
            <span className="font-medium text-slate-900">
              {getLocationLabel(session)}
            </span>
          </div>
          <div className="mt-1 flex justify-between text-sm">
            <span className="text-slate-500">Duree jusqu&apos;ici</span>
            <span className="font-medium text-slate-900">
              {formatWorkSessionDuration(currentDuration)}
            </span>
          </div>
        </div>

        <div className="mt-4 text-xs text-slate-500">
          Cette session sera marquee comme &quot;Fermee manuellement&quot;.
        </div>

        {/* Actions */}
        <div className="mt-6 flex justify-end gap-3">
          <button
            onClick={onClose}
            disabled={isClosing}
            className="rounded-md border border-slate-300 px-4 py-2 text-sm font-medium text-slate-700 hover:bg-slate-50 disabled:opacity-50"
          >
            Annuler
          </button>
          <button
            onClick={() => onConfirm(session.id, session.employeeId)}
            disabled={isClosing}
            className="rounded-md bg-red-600 px-4 py-2 text-sm font-medium text-white hover:bg-red-700 disabled:opacity-50"
          >
            {isClosing ? 'Fermeture...' : 'Fermer la session'}
          </button>
        </div>
      </div>
    </div>
  );
}
