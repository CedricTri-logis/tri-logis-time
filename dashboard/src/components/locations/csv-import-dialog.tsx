'use client';

import { useState, useCallback, useRef } from 'react';
import { toast } from 'sonner';
import {
  Upload,
  FileSpreadsheet,
  CheckCircle2,
  XCircle,
  AlertCircle,
  Download,
  X,
  Loader2,
} from 'lucide-react';
import { Button } from '@/components/ui/button';
import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
  DialogDescription,
  DialogFooter,
} from '@/components/ui/dialog';
import { Card, CardContent } from '@/components/ui/card';
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from '@/components/ui/table';
import {
  parseAndValidateCsv,
  validateFile,
  formatFileSize,
  downloadCsvTemplate,
  prepareForBulkInsert,
} from '@/lib/utils/csv-parser';
import { useBulkInsertLocations } from '@/lib/hooks/use-locations';
import type { CsvValidationResult, CsvImportSummary } from '@/types/location';

interface CsvImportDialogProps {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  onSuccess?: () => void;
}

type ImportStep = 'upload' | 'preview' | 'importing' | 'complete';

/**
 * Dialog for bulk importing locations via CSV file.
 */
export function CsvImportDialog({
  open,
  onOpenChange,
  onSuccess,
}: CsvImportDialogProps) {
  const [step, setStep] = useState<ImportStep>('upload');
  const [file, setFile] = useState<File | null>(null);
  const [validRows, setValidRows] = useState<CsvValidationResult[]>([]);
  const [invalidRows, setInvalidRows] = useState<CsvValidationResult[]>([]);
  const [parseErrors, setParseErrors] = useState<string[]>([]);
  const [headerErrors, setHeaderErrors] = useState<string[]>([]);
  const [importResult, setImportResult] = useState<CsvImportSummary | null>(null);

  const { bulkInsert, isInserting, progress } = useBulkInsertLocations();
  const fileInputRef = useRef<HTMLInputElement>(null);

  // Reset state when dialog closes
  const handleOpenChange = useCallback(
    (newOpen: boolean) => {
      if (!newOpen) {
        setStep('upload');
        setFile(null);
        setValidRows([]);
        setInvalidRows([]);
        setParseErrors([]);
        setHeaderErrors([]);
        setImportResult(null);
      }
      onOpenChange(newOpen);
    },
    [onOpenChange]
  );

  // Handle file selection
  const handleFileSelect = useCallback(
    async (event: React.ChangeEvent<HTMLInputElement>) => {
      const selectedFile = event.target.files?.[0];
      if (!selectedFile) return;

      // Validate file
      const validation = validateFile(selectedFile);
      if (!validation.valid) {
        toast.error(validation.error);
        return;
      }

      setFile(selectedFile);

      // Parse and validate CSV
      const result = await parseAndValidateCsv(selectedFile);

      setValidRows(result.validRows);
      setInvalidRows(result.invalidRows);
      setParseErrors(result.parseErrors);
      setHeaderErrors(result.headerErrors);

      if (result.headerErrors.length > 0 || result.parseErrors.length > 0) {
        toast.error('Le fichier CSV contient des erreurs. Veuillez corriger et réessayer.');
        return;
      }

      if (result.validRows.length === 0) {
        toast.error('Aucune ligne valide trouvée dans le fichier CSV.');
        return;
      }

      setStep('preview');
    },
    []
  );

  // Handle file drop
  const handleDrop = useCallback(
    async (event: React.DragEvent<HTMLDivElement>) => {
      event.preventDefault();
      const droppedFile = event.dataTransfer.files?.[0];
      if (!droppedFile) return;

      // Create a synthetic event for handleFileSelect
      const syntheticEvent = {
        target: { files: [droppedFile] },
      } as unknown as React.ChangeEvent<HTMLInputElement>;

      await handleFileSelect(syntheticEvent);
    },
    [handleFileSelect]
  );

  // Handle import
  const handleImport = useCallback(async () => {
    if (validRows.length === 0) return;

    setStep('importing');

    try {
      const locationsToInsert = prepareForBulkInsert(validRows);
      const results = await bulkInsert(locationsToInsert);

      const imported = results.filter((r) => r.success);
      const failed = results.filter((r) => !r.success);

      const summary: CsvImportSummary = {
        status: failed.length === 0 ? 'success' : imported.length === 0 ? 'failed' : 'partial',
        totalRows: validRows.length + invalidRows.length,
        importedCount: imported.length,
        skippedCount: invalidRows.length,
        failedCount: failed.length,
        skippedRows: invalidRows.map((row) => ({
          rowIndex: row.rowIndex + 2, // +2 for header row and 1-based index
          errors: row.errors,
        })),
        failedRows: failed.map((r, idx) => ({
          rowIndex: validRows[idx].rowIndex + 2,
          error: r.errorMessage || 'Unknown error',
        })),
      };

      setImportResult(summary);
      setStep('complete');

      if (summary.status === 'success') {
        toast.success(`${summary.importedCount} emplacements importés avec succès`);
        onSuccess?.();
      } else if (summary.status === 'partial') {
        toast.warning(
          `${summary.importedCount} sur ${summary.totalRows} emplacements importés`
        );
        onSuccess?.();
      } else {
        toast.error('Échec de l\'importation. Veuillez vérifier les erreurs et réessayer.');
      }
    } catch (error) {
      toast.error('Échec de l\'importation. Veuillez réessayer.');
      setStep('preview');
    }
  }, [validRows, invalidRows, bulkInsert, onSuccess]);

  return (
    <Dialog open={open} onOpenChange={handleOpenChange}>
      <DialogContent className="max-w-3xl max-h-[90vh] overflow-y-auto">
        <DialogHeader>
          <DialogTitle className="flex items-center gap-2">
            <FileSpreadsheet className="h-5 w-5" />
            Importer des emplacements depuis un CSV
          </DialogTitle>
          <DialogDescription>
            Téléversez un fichier CSV pour importer plusieurs emplacements en une fois.
          </DialogDescription>
        </DialogHeader>

        {step === 'upload' && (
          <UploadStep
            fileInputRef={fileInputRef}
            onFileSelect={handleFileSelect}
            onDrop={handleDrop}
            headerErrors={headerErrors}
            parseErrors={parseErrors}
          />
        )}

        {step === 'preview' && (
          <PreviewStep
            file={file}
            validRows={validRows}
            invalidRows={invalidRows}
            onBack={() => setStep('upload')}
            onImport={handleImport}
          />
        )}

        {step === 'importing' && <ImportingStep progress={progress} />}

        {step === 'complete' && (
          <CompleteStep
            result={importResult}
            onClose={() => handleOpenChange(false)}
          />
        )}
      </DialogContent>
    </Dialog>
  );
}

interface UploadStepProps {
  fileInputRef: React.RefObject<HTMLInputElement | null>;
  onFileSelect: (event: React.ChangeEvent<HTMLInputElement>) => void;
  onDrop: (event: React.DragEvent<HTMLDivElement>) => void;
  headerErrors: string[];
  parseErrors: string[];
}

function UploadStep({
  fileInputRef,
  onFileSelect,
  onDrop,
  headerErrors,
  parseErrors,
}: UploadStepProps) {
  const [isDragging, setIsDragging] = useState(false);

  return (
    <div className="space-y-4">
      {/* Drop zone */}
      <div
        className={`border-2 border-dashed rounded-lg p-8 text-center transition-colors ${
          isDragging
            ? 'border-blue-500 bg-blue-50'
            : 'border-slate-300 hover:border-slate-400'
        }`}
        onDragOver={(e) => {
          e.preventDefault();
          setIsDragging(true);
        }}
        onDragLeave={() => setIsDragging(false)}
        onDrop={(e) => {
          setIsDragging(false);
          onDrop(e);
        }}
      >
        <Upload className="h-10 w-10 text-slate-400 mx-auto mb-4" />
        <p className="text-sm text-slate-600 mb-2">
          Glissez-déposez votre fichier CSV ici, ou
        </p>
        <Button
          variant="outline"
          onClick={() => fileInputRef.current?.click()}
        >
          Parcourir les fichiers
        </Button>
        <input
          ref={fileInputRef}
          type="file"
          accept=".csv"
          className="hidden"
          onChange={onFileSelect}
        />
        <p className="text-xs text-slate-400 mt-2">
          Taille maximale du fichier : 5 Mo
        </p>
      </div>

      {/* Errors */}
      {(headerErrors.length > 0 || parseErrors.length > 0) && (
        <Card className="border-red-200 bg-red-50">
          <CardContent className="pt-4">
            <div className="flex items-start gap-2">
              <XCircle className="h-5 w-5 text-red-500 flex-shrink-0 mt-0.5" />
              <div className="space-y-1">
                {headerErrors.map((err, i) => (
                  <p key={i} className="text-sm text-red-700">
                    {err}
                  </p>
                ))}
                {parseErrors.map((err, i) => (
                  <p key={i} className="text-sm text-red-700">
                    {err}
                  </p>
                ))}
              </div>
            </div>
          </CardContent>
        </Card>
      )}

      {/* Template download */}
      <div className="flex items-center justify-between bg-slate-50 rounded-lg p-4">
        <div>
          <p className="text-sm font-medium text-slate-700">Besoin d'un modèle ?</p>
          <p className="text-xs text-slate-500">
            Téléchargez notre modèle CSV avec les colonnes requises
          </p>
        </div>
        <Button variant="outline" size="sm" onClick={downloadCsvTemplate}>
          <Download className="h-4 w-4 mr-2" />
          Télécharger le modèle
        </Button>
      </div>

      {/* Required columns */}
      <div className="text-xs text-slate-500">
        <p className="font-medium mb-1">Colonnes requises :</p>
        <code className="bg-slate-100 px-1 py-0.5 rounded">
          name, location_type, latitude, longitude
        </code>
        <p className="mt-1">Optionnel : radius_meters, address, notes, is_active</p>
      </div>
    </div>
  );
}

interface PreviewStepProps {
  file: File | null;
  validRows: CsvValidationResult[];
  invalidRows: CsvValidationResult[];
  onBack: () => void;
  onImport: () => void;
}

function PreviewStep({
  file,
  validRows,
  invalidRows,
  onBack,
  onImport,
}: PreviewStepProps) {
  const [showInvalid, setShowInvalid] = useState(false);

  return (
    <div className="space-y-4">
      {/* File info */}
      <div className="flex items-center justify-between bg-slate-50 rounded-lg p-3">
        <div className="flex items-center gap-3">
          <FileSpreadsheet className="h-8 w-8 text-slate-400" />
          <div>
            <p className="text-sm font-medium text-slate-700">{file?.name}</p>
            <p className="text-xs text-slate-500">
              {file && formatFileSize(file.size)}
            </p>
          </div>
        </div>
        <Button variant="ghost" size="sm" onClick={onBack}>
          Changer de fichier
        </Button>
      </div>

      {/* Summary */}
      <div className="grid grid-cols-2 gap-4">
        <div className="flex items-center gap-2 p-3 bg-green-50 rounded-lg">
          <CheckCircle2 className="h-5 w-5 text-green-600" />
          <div>
            <p className="text-sm font-medium text-green-700">
              {validRows.length} valide{validRows.length !== 1 ? 's' : ''}
            </p>
            <p className="text-xs text-green-600">Prêt à importer</p>
          </div>
        </div>
        {invalidRows.length > 0 && (
          <div className="flex items-center gap-2 p-3 bg-yellow-50 rounded-lg">
            <AlertCircle className="h-5 w-5 text-yellow-600" />
            <div>
              <p className="text-sm font-medium text-yellow-700">
                {invalidRows.length} invalide{invalidRows.length !== 1 ? 's' : ''}
              </p>
              <button
                className="text-xs text-yellow-600 hover:underline"
                onClick={() => setShowInvalid(!showInvalid)}
              >
                {showInvalid ? 'Masquer les détails' : 'Voir les détails'}
              </button>
            </div>
          </div>
        )}
      </div>

      {/* Invalid rows details */}
      {showInvalid && invalidRows.length > 0 && (
        <Card className="border-yellow-200">
          <CardContent className="pt-4">
            <p className="text-sm font-medium text-yellow-700 mb-2">
              Lignes invalides (seront ignorées)
            </p>
            <div className="max-h-[150px] overflow-y-auto space-y-2 text-xs">
              {invalidRows.slice(0, 10).map((row) => (
                <div key={row.rowIndex} className="flex gap-2">
                  <span className="text-slate-500">Ligne {row.rowIndex + 2} :</span>
                  <span className="text-red-600">{row.errors.join('; ')}</span>
                </div>
              ))}
              {invalidRows.length > 10 && (
                <p className="text-slate-500">
                  +{invalidRows.length - 10} autres lignes invalides
                </p>
              )}
            </div>
          </CardContent>
        </Card>
      )}

      {/* Preview table */}
      <div className="border rounded-lg overflow-hidden">
        <div className="max-h-[250px] overflow-y-auto">
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead className="w-[50px]">#</TableHead>
                <TableHead>Nom</TableHead>
                <TableHead>Type</TableHead>
                <TableHead>Coordonnées</TableHead>
                <TableHead>Rayon</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {validRows.slice(0, 10).map((row) => (
                <TableRow key={row.rowIndex}>
                  <TableCell className="text-slate-500">
                    {row.rowIndex + 2}
                  </TableCell>
                  <TableCell className="font-medium">{row.data?.name}</TableCell>
                  <TableCell>{row.data?.locationType}</TableCell>
                  <TableCell className="text-xs">
                    {row.data?.latitude.toFixed(4)}, {row.data?.longitude.toFixed(4)}
                  </TableCell>
                  <TableCell>{row.data?.radiusMeters}m</TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
        </div>
        {validRows.length > 10 && (
          <div className="px-4 py-2 bg-slate-50 text-xs text-slate-500 border-t">
            Affichage de 10 sur {validRows.length} lignes
          </div>
        )}
      </div>

      {/* Actions */}
      <DialogFooter>
        <Button variant="outline" onClick={onBack}>
          Retour
        </Button>
        <Button onClick={onImport} disabled={validRows.length === 0}>
          Importer {validRows.length} emplacements
        </Button>
      </DialogFooter>
    </div>
  );
}

interface ImportingStepProps {
  progress: { current: number; total: number } | null;
}

function ImportingStep({ progress }: ImportingStepProps) {
  const percent = progress
    ? Math.round((progress.current / progress.total) * 100)
    : 0;

  return (
    <div className="py-12 text-center">
      <Loader2 className="h-12 w-12 text-blue-500 animate-spin mx-auto mb-4" />
      <p className="text-lg font-medium text-slate-700 mb-2">
        Importation des emplacements...
      </p>
      {progress && (
        <div className="max-w-xs mx-auto">
          <div className="flex justify-between text-xs text-slate-500 mb-1">
            <span>Progression</span>
            <span>
              {progress.current} / {progress.total}
            </span>
          </div>
          <div className="h-2 bg-slate-100 rounded-full overflow-hidden">
            <div
              className="h-full bg-blue-500 transition-all"
              style={{ width: `${percent}%` }}
            />
          </div>
        </div>
      )}
    </div>
  );
}

interface CompleteStepProps {
  result: CsvImportSummary | null;
  onClose: () => void;
}

function CompleteStep({ result, onClose }: CompleteStepProps) {
  if (!result) return null;

  const isSuccess = result.status === 'success';
  const isPartial = result.status === 'partial';

  return (
    <div className="space-y-4">
      <div
        className={`py-8 text-center rounded-lg ${
          isSuccess
            ? 'bg-green-50'
            : isPartial
            ? 'bg-yellow-50'
            : 'bg-red-50'
        }`}
      >
        {isSuccess ? (
          <CheckCircle2 className="h-12 w-12 text-green-500 mx-auto mb-4" />
        ) : isPartial ? (
          <AlertCircle className="h-12 w-12 text-yellow-500 mx-auto mb-4" />
        ) : (
          <XCircle className="h-12 w-12 text-red-500 mx-auto mb-4" />
        )}
        <p
          className={`text-lg font-medium ${
            isSuccess
              ? 'text-green-700'
              : isPartial
              ? 'text-yellow-700'
              : 'text-red-700'
          }`}
        >
          {isSuccess
            ? 'Importation terminée !'
            : isPartial
            ? 'Importation partielle'
            : 'Échec de l\'importation'}
        </p>
      </div>

      {/* Summary stats */}
      <div className="grid grid-cols-3 gap-4">
        <div className="text-center p-3 bg-slate-50 rounded-lg">
          <p className="text-2xl font-bold text-slate-900">
            {result.importedCount}
          </p>
          <p className="text-xs text-slate-500">Importés</p>
        </div>
        <div className="text-center p-3 bg-slate-50 rounded-lg">
          <p className="text-2xl font-bold text-slate-900">
            {result.skippedCount}
          </p>
          <p className="text-xs text-slate-500">Ignorés</p>
        </div>
        <div className="text-center p-3 bg-slate-50 rounded-lg">
          <p className="text-2xl font-bold text-slate-900">
            {result.failedCount}
          </p>
          <p className="text-xs text-slate-500">Échoués</p>
        </div>
      </div>

      {/* Error details */}
      {(result.skippedRows.length > 0 || result.failedRows.length > 0) && (
        <Card className="border-yellow-200">
          <CardContent className="pt-4 max-h-[200px] overflow-y-auto text-xs">
            {result.skippedRows.slice(0, 5).map((row) => (
              <div key={row.rowIndex} className="flex gap-2 mb-1">
                <span className="text-slate-500">Ligne {row.rowIndex} :</span>
                <span className="text-yellow-600">
                  Ignorée - {row.errors.join('; ')}
                </span>
              </div>
            ))}
            {result.failedRows.slice(0, 5).map((row) => (
              <div key={row.rowIndex} className="flex gap-2 mb-1">
                <span className="text-slate-500">Ligne {row.rowIndex} :</span>
                <span className="text-red-600">Échoué - {row.error}</span>
              </div>
            ))}
          </CardContent>
        </Card>
      )}

      <DialogFooter>
        <Button onClick={onClose}>Fermer</Button>
      </DialogFooter>
    </div>
  );
}
