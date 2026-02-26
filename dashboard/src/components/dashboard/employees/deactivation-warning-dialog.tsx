'use client';

import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from '@/components/ui/dialog';
import { Button } from '@/components/ui/button';
import { AlertTriangle } from 'lucide-react';

interface DeactivationWarningDialogProps {
  isOpen: boolean;
  onClose: () => void;
  onConfirm: () => void;
  isSubmitting?: boolean;
}

export function DeactivationWarningDialog({
  isOpen,
  onClose,
  onConfirm,
  isSubmitting = false,
}: DeactivationWarningDialogProps) {
  return (
    <Dialog open={isOpen} onOpenChange={(open) => !open && onClose()}>
      <DialogContent>
        <DialogHeader>
          <div className="flex items-center gap-3">
            <div className="rounded-full bg-amber-100 p-2">
              <AlertTriangle className="h-5 w-5 text-amber-600" />
            </div>
            <DialogTitle>Avertissement de quart actif</DialogTitle>
          </div>
          <DialogDescription className="pt-2">
            Cet employé a actuellement un quart de travail actif en cours. Si vous procédez
            à la désactivation, son quart restera ouvert et devra être
            fermé manuellement.
          </DialogDescription>
        </DialogHeader>
        <div className="rounded-md border border-amber-200 bg-amber-50 p-3">
          <p className="text-sm text-amber-800">
            <strong>Important :</strong> L&apos;employé sera immédiatement bloqué et ne pourra
            plus se connecter ni pointer sa sortie. Vous devrez peut-être terminer
            manuellement son quart dans la section de gestion des quarts.
          </p>
        </div>
        <DialogFooter className="gap-2 sm:gap-0">
          <Button variant="outline" onClick={onClose} disabled={isSubmitting}>
            Annuler
          </Button>
          <Button
            variant="destructive"
            onClick={onConfirm}
            disabled={isSubmitting}
          >
            {isSubmitting ? 'Désactivation...' : 'Désactiver quand même'}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
