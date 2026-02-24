'use client';

/**
 * Report Download Component
 * Spec: 013-reports-export
 *
 * Handles report download with signed URLs and expiration info
 */

import { useState } from 'react';
import { Download, FileText, Clock, CheckCircle, ExternalLink } from 'lucide-react';
import { Button } from '@/components/ui/button';
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card';
import { formatBytes } from '@/lib/validations/reports';
import type { ReportFormat, ReportType, REPORT_TYPE_INFO } from '@/types/reports';

interface ReportDownloadProps {
  downloadUrl: string;
  fileName?: string;
  fileSize?: number;
  recordCount?: number;
  reportType?: ReportType;
  format?: ReportFormat;
  expiresAt?: string;
  onDownloadComplete?: () => void;
}

export function ReportDownload({
  downloadUrl,
  fileName,
  fileSize,
  recordCount,
  reportType,
  format = 'pdf',
  expiresAt,
  onDownloadComplete,
}: ReportDownloadProps) {
  const [isDownloading, setIsDownloading] = useState(false);
  const [downloaded, setDownloaded] = useState(false);

  const handleDownload = async () => {
    setIsDownloading(true);

    try {
      // Trigger download
      const link = document.createElement('a');
      link.href = downloadUrl;
      link.download = fileName || `report.${format}`;
      link.target = '_blank';
      link.rel = 'noopener noreferrer';
      document.body.appendChild(link);
      link.click();
      document.body.removeChild(link);

      setDownloaded(true);
      onDownloadComplete?.();
    } catch (error) {
      console.error('Download failed:', error);
    } finally {
      setIsDownloading(false);
    }
  };

  // Calculate time remaining until expiry
  const getExpiryInfo = () => {
    if (!expiresAt) return null;

    const now = new Date();
    const expiry = new Date(expiresAt);
    const diff = expiry.getTime() - now.getTime();

    if (diff <= 0) {
      return { expired: true, text: 'Link expired' };
    }

    const days = Math.floor(diff / (1000 * 60 * 60 * 24));
    const hours = Math.floor((diff % (1000 * 60 * 60 * 24)) / (1000 * 60 * 60));

    if (days > 0) {
      return { expired: false, text: `Expires in ${days} day${days > 1 ? 's' : ''}` };
    }
    return { expired: false, text: `Expires in ${hours} hour${hours > 1 ? 's' : ''}` };
  };

  const expiryInfo = getExpiryInfo();

  return (
    <Card className="border-green-200 bg-green-50">
      <CardHeader className="pb-3">
        <div className="flex items-center gap-3">
          <div className="flex h-10 w-10 items-center justify-center rounded-full bg-green-100">
            <CheckCircle className="h-5 w-5 text-green-600" />
          </div>
          <div>
            <CardTitle className="text-lg text-green-900">Report Ready</CardTitle>
            <CardDescription className="text-green-700">
              Your report has been generated and is ready to download
            </CardDescription>
          </div>
        </div>
      </CardHeader>

      <CardContent className="space-y-4">
        {/* File info */}
        <div className="flex flex-wrap gap-4 text-sm">
          {reportType && (
            <div className="flex items-center gap-1.5 text-slate-600">
              <FileText className="h-4 w-4" />
              <span className="capitalize">{reportType.replace('_', ' ')}</span>
            </div>
          )}
          {fileSize && (
            <div className="flex items-center gap-1.5 text-slate-600">
              <span>{formatBytes(fileSize)}</span>
            </div>
          )}
          {recordCount && (
            <div className="flex items-center gap-1.5 text-slate-600">
              <span>{recordCount.toLocaleString()} records</span>
            </div>
          )}
          {expiryInfo && (
            <div className={`flex items-center gap-1.5 ${expiryInfo.expired ? 'text-red-600' : 'text-slate-500'}`}>
              <Clock className="h-4 w-4" />
              <span>{expiryInfo.text}</span>
            </div>
          )}
        </div>

        {/* Download button */}
        {expiryInfo?.expired ? (
          <div className="rounded-lg bg-red-100 p-3 text-sm text-red-800">
            This download link has expired. Please generate a new report.
          </div>
        ) : (
          <div className="flex gap-2">
            <Button
              onClick={handleDownload}
              disabled={isDownloading}
              className="flex-1 bg-green-600 hover:bg-green-700"
            >
              {isDownloading ? (
                <>
                  <span className="mr-2 animate-spin">⏳</span>
                  Downloading...
                </>
              ) : downloaded ? (
                <>
                  <CheckCircle className="mr-2 h-4 w-4" />
                  Downloaded
                </>
              ) : (
                <>
                  <Download className="mr-2 h-4 w-4" />
                  Download {format.toUpperCase()}
                </>
              )}
            </Button>

            <Button
              variant="outline"
              asChild
              className="border-green-300 text-green-700 hover:bg-green-100"
            >
              <a href={downloadUrl} target="_blank" rel="noopener noreferrer">
                <ExternalLink className="h-4 w-4" />
              </a>
            </Button>
          </div>
        )}

        {/* Help text */}
        {downloaded && (
          <p className="text-xs text-slate-500">
            If the download didn&apos;t start automatically, click the button again or use the
            external link.
          </p>
        )}
      </CardContent>
    </Card>
  );
}
