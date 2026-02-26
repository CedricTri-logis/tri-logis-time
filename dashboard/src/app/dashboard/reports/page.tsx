'use client';

import Link from 'next/link';
import {
  Clock,
  Users,
  Calendar,
  FileDown,
  ArrowRight,
} from 'lucide-react';
import {
  Card,
  CardContent,
  CardDescription,
  CardFooter,
  CardHeader,
  CardTitle,
} from '@/components/ui/card';
import { Button } from '@/components/ui/button';
import type { ReportType } from '@/types/reports';

interface ReportCard {
  type: ReportType;
  title: string;
  description: string;
  icon: React.ComponentType<{ className?: string }>;
  href: string;
  features: string[];
  priority: 'P1' | 'P2' | 'P3' | 'P4';
}

const reportCards: ReportCard[] = [
  {
    type: 'timesheet',
    title: 'Rapport de feuille de temps',
    description: 'Données complètes de feuille de temps pour le traitement de la paie',
    icon: Clock,
    href: '/dashboard/reports/timesheet',
    features: [
      'Heures de quart par employé',
      'Calculs des heures supplémentaires',
      'Avertissements de quarts incomplets',
      'Export PDF et CSV',
    ],
    priority: 'P1',
  },
  {
    type: 'shift_history',
    title: 'Export de l\'historique des quarts',
    description: 'Dossiers détaillés des quarts avec données GPS par employé',
    icon: FileDown,
    href: '/dashboard/reports/exports',
    features: [
      'Export individuel ou en lot',
      'Nombre de points GPS',
      'Suivi des distances',
      'Filtrage par plage de dates',
    ],
    priority: 'P2',
  },
  {
    type: 'activity_summary',
    title: 'Résumé d\'activité de l\'équipe',
    description: 'Métriques agrégées et tendances pour la planification d\'équipe',
    icon: Users,
    href: '/dashboard/reports/activity',
    features: [
      'Heures totales par équipe',
      'Répartition par jour de la semaine',
      'Nombre d\'employés actifs',
      'Comparaisons de périodes',
    ],
    priority: 'P2',
  },
  {
    type: 'attendance',
    title: 'Rapport de présence',
    description: 'Suivi des présences et des absences des employés',
    icon: Calendar,
    href: '/dashboard/reports/attendance',
    features: [
      'Jours travaillés vs absents',
      'Taux de présence %',
      'Vue calendrier',
      'Analyse des tendances',
    ],
    priority: 'P3',
  },
];

export default function ReportsPage() {
  return (
    <div className="space-y-6">
      {/* Page header */}
      <div>
        <h1 className="text-2xl font-bold text-slate-900">Rapports et exportation</h1>
        <p className="text-sm text-slate-500 mt-1">
          Générez et téléchargez des rapports pour la paie, la conformité et l&apos;analytique
        </p>
      </div>

      {/* Report type cards */}
      <div className="grid gap-6 md:grid-cols-2">
        {reportCards.map((card) => (
          <Card key={card.type} className="flex flex-col">
            <CardHeader>
              <div className="flex items-center justify-between">
                <div className="flex h-10 w-10 items-center justify-center rounded-lg bg-slate-100">
                  <card.icon className="h-5 w-5 text-slate-700" />
                </div>
                <span className="text-xs font-medium text-slate-400">
                  {card.priority}
                </span>
              </div>
              <CardTitle className="mt-4">{card.title}</CardTitle>
              <CardDescription>{card.description}</CardDescription>
            </CardHeader>
            <CardContent className="flex-1">
              <ul className="space-y-2">
                {card.features.map((feature) => (
                  <li
                    key={feature}
                    className="flex items-center gap-2 text-sm text-slate-600"
                  >
                    <span className="h-1.5 w-1.5 rounded-full bg-slate-400" />
                    {feature}
                  </li>
                ))}
              </ul>
            </CardContent>
            <CardFooter>
              <Button asChild className="w-full">
                <Link href={card.href}>
                  Générer le rapport
                  <ArrowRight className="ml-2 h-4 w-4" />
                </Link>
              </Button>
            </CardFooter>
          </Card>
        ))}
      </div>

      {/* Quick actions */}
      <Card>
        <CardHeader>
          <CardTitle className="text-lg">Actions rapides</CardTitle>
        </CardHeader>
        <CardContent>
          <div className="flex flex-wrap gap-3">
            <Button variant="outline" asChild>
              <Link href="/dashboard/reports/schedules">
                Gérer les rapports programmés
              </Link>
            </Button>
            <Button variant="outline" asChild>
              <Link href="/dashboard/reports/history">
                Voir l&apos;historique des rapports
              </Link>
            </Button>
          </div>
        </CardContent>
      </Card>
    </div>
  );
}
