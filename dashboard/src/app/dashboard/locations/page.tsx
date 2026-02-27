'use client';

import { useState, useCallback, useMemo, useEffect } from 'react';
import { useRouter } from 'next/navigation';
import dynamic from 'next/dynamic';
import {
  MapPin,
  Plus,
  Upload,
  List,
  Map as MapIcon,
  Search,
  Filter,
  X,
  Lightbulb,
} from 'lucide-react';
import { toast } from 'sonner';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Skeleton } from '@/components/ui/skeleton';
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from '@/components/ui/select';
import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
  DialogDescription,
} from '@/components/ui/dialog';
import {
  Pagination,
  PaginationContent,
  PaginationItem,
  PaginationLink,
  PaginationNext,
  PaginationPrevious,
} from '@/components/ui/pagination';
import { Tabs, TabsList, TabsTrigger, TabsContent } from '@/components/ui/tabs';
import { LocationForm } from '@/components/locations/location-form';
import { CsvImportDialog } from '@/components/locations/csv-import-dialog';
import { SuggestedLocationsTab } from '@/components/locations/suggested-locations-tab';
import { useLocations, useActiveLocations, useLocationMutations, type LocationFilters } from '@/lib/hooks/use-locations';
import {
  LOCATION_TYPE_VALUES,
  LOCATION_TYPE_LABELS,
  type LocationFormInput,
} from '@/lib/validations/location';
import {
  LOCATION_TYPE_COLORS,
  getLocationTypeLabel,
} from '@/lib/utils/segment-colors';
import type { Location, LocationType } from '@/types/location';
import { format } from 'date-fns';
import { supabaseClient } from '@/lib/supabase/client';

// Dynamically import the locations map to avoid SSR issues
const LocationsOverviewMap = dynamic(
  () => import('@/components/locations/google-locations-overview-map').then((mod) => mod.GoogleLocationsOverviewMap),
  {
    ssr: false,
    loading: () => <MapLoadingSkeleton />,
  }
);

function MapLoadingSkeleton() {
  return (
    <Card>
      <CardHeader className="pb-2">
        <div className="flex items-center justify-between">
          <Skeleton className="h-5 w-32" />
          <Skeleton className="h-4 w-20" />
        </div>
      </CardHeader>
      <CardContent className="p-0">
        <Skeleton className="h-[500px] w-full rounded-b-lg" />
      </CardContent>
    </Card>
  );
}

const PAGE_SIZE = 20;

type ViewMode = 'list' | 'map';

export default function LocationsPage() {
  const router = useRouter();
  const [search, setSearch] = useState('');
  const [debouncedSearch, setDebouncedSearch] = useState('');
  const [locationType, setLocationType] = useState<LocationType | ''>('');
  const [activeFilter, setActiveFilter] = useState<'all' | 'active' | 'inactive'>('all');
  const [currentPage, setCurrentPage] = useState(1);
  const [viewMode, setViewMode] = useState<ViewMode>('list');
  const [isCreateDialogOpen, setIsCreateDialogOpen] = useState(false);
  const [isImportDialogOpen, setIsImportDialogOpen] = useState(false);
  const [activeTab, setActiveTab] = useState<string>('locations');
  const [createPrefill, setCreatePrefill] = useState<{
    latitude: number;
    longitude: number;
    name: string;
    address: string;
  } | null>(null);
  const [suggestedRefreshKey, setSuggestedRefreshKey] = useState(0);

  // Active locations for the suggested tab overlay
  const { locations: activeLocations } = useActiveLocations();

  // Debounce search
  useEffect(() => {
    const timer = setTimeout(() => {
      if (search !== debouncedSearch) {
        setDebouncedSearch(search);
        setCurrentPage(1);
      }
    }, 300);
    return () => clearTimeout(timer);
  }, [search, debouncedSearch]);

  // Build filters for list view (paginated)
  const listFilters: LocationFilters = useMemo(() => {
    const result: LocationFilters = {
      limit: PAGE_SIZE,
      offset: (currentPage - 1) * PAGE_SIZE,
      sortBy: 'name',
      sortOrder: 'asc',
    };
    if (debouncedSearch) {
      result.search = debouncedSearch;
    }
    if (locationType) {
      result.locationType = locationType;
    }
    if (activeFilter === 'active') {
      result.isActive = true;
    } else if (activeFilter === 'inactive') {
      result.isActive = false;
    }
    return result;
  }, [debouncedSearch, locationType, activeFilter, currentPage]);

  // Build filters for map view (fetch all matching locations, up to 500)
  const mapFilters: LocationFilters = useMemo(() => {
    const result: LocationFilters = {
      limit: 500, // Higher limit for map view
      offset: 0,
      sortBy: 'name',
      sortOrder: 'asc',
    };
    if (debouncedSearch) {
      result.search = debouncedSearch;
    }
    if (locationType) {
      result.locationType = locationType;
    }
    if (activeFilter === 'active') {
      result.isActive = true;
    } else if (activeFilter === 'inactive') {
      result.isActive = false;
    }
    return result;
  }, [debouncedSearch, locationType, activeFilter]);

  // Use appropriate filters based on view mode
  const filters = viewMode === 'map' ? mapFilters : listFilters;

  const { locations, totalCount, isLoading, refetch } = useLocations(filters);
  const { createLocation, isCreating } = useLocationMutations();

  const totalPages = Math.ceil(totalCount / PAGE_SIZE);

  const handleClearFilters = useCallback(() => {
    setSearch('');
    setLocationType('');
    setActiveFilter('all');
    setCurrentPage(1);
  }, []);

  const handleTypeChange = useCallback((value: string) => {
    setLocationType(value === 'all' ? '' : (value as LocationType));
    setCurrentPage(1);
  }, []);

  const handleActiveChange = useCallback((value: 'all' | 'active' | 'inactive') => {
    setActiveFilter(value);
    setCurrentPage(1);
  }, []);

  const handleCreateLocation = useCallback(
    async (data: LocationFormInput) => {
      try {
        const newLocation = await createLocation({
          name: data.name,
          locationType: data.location_type,
          latitude: data.latitude,
          longitude: data.longitude,
          radiusMeters: data.radius_meters,
          address: data.address ?? null,
          notes: data.notes ?? null,
          isActive: data.is_active,
        });
        toast.success('Emplacement créé avec succès');
        setIsCreateDialogOpen(false);
        refetch();

        // If created from Suggested tab, rematch nearby trips
        if (createPrefill && newLocation?.id) {
          try {
            const { data: rematchResult } = await supabaseClient.rpc('rematch_trips_near_location', {
              p_location_id: newLocation.id,
            });
            const row = rematchResult?.[0];
            const totalMatched = (row?.matched_start ?? 0) + (row?.matched_end ?? 0);
            if (totalMatched > 0) {
              toast.success(`${totalMatched} trajet(s) associé(s) automatiquement`);
            }
          } catch {
            // Non-blocking — rematch failure shouldn't affect location creation
          }
          setSuggestedRefreshKey((k) => k + 1);
        }
      } catch (error) {
        toast.error('Échec de la création de l\'emplacement');
      }
    },
    [createLocation, refetch, createPrefill]
  );

  const handleViewLocation = useCallback(
    (location: Location) => {
      router.push(`/dashboard/locations/${location.id}`);
    },
    [router]
  );

  // Page numbers for pagination
  const pageNumbers = useMemo(() => {
    const pages: number[] = [];
    const maxVisiblePages = 5;
    let start = Math.max(1, currentPage - Math.floor(maxVisiblePages / 2));
    const end = Math.min(totalPages, start + maxVisiblePages - 1);
    if (end - start < maxVisiblePages - 1) {
      start = Math.max(1, end - maxVisiblePages + 1);
    }
    for (let i = start; i <= end; i++) {
      pages.push(i);
    }
    return pages;
  }, [currentPage, totalPages]);

  const hasFilters = debouncedSearch || locationType || activeFilter !== 'all';

  return (
    <div className="space-y-6">
      {/* Page Header */}
      <div className="flex items-center justify-between">
        <div className="flex items-center gap-3">
          <div className="rounded-lg bg-slate-100 p-2">
            <MapPin className="h-6 w-6 text-slate-600" />
          </div>
          <div>
            <h1 className="text-2xl font-semibold text-slate-900">Emplacements</h1>
            <p className="text-sm text-slate-500">
              {isLoading
                ? 'Chargement...'
                : `${totalCount} emplacement${totalCount !== 1 ? 's' : ''}`}
            </p>
          </div>
        </div>
        <div className="flex items-center gap-2">
          {/* View Toggle */}
          <div className="flex items-center rounded-lg border bg-white p-1">
            <Button
              variant={viewMode === 'list' ? 'secondary' : 'ghost'}
              size="sm"
              onClick={() => setViewMode('list')}
              className="h-8 px-3"
            >
              <List className="h-4 w-4" />
            </Button>
            <Button
              variant={viewMode === 'map' ? 'secondary' : 'ghost'}
              size="sm"
              onClick={() => setViewMode('map')}
              className="h-8 px-3"
            >
              <MapIcon className="h-4 w-4" />
            </Button>
          </div>
          <Button
            variant="outline"
            onClick={() => setIsImportDialogOpen(true)}
          >
            <Upload className="h-4 w-4 mr-2" />
            Importer CSV
          </Button>
          <Button onClick={() => setIsCreateDialogOpen(true)}>
            <Plus className="h-4 w-4 mr-2" />
            Ajouter un emplacement
          </Button>
        </div>
      </div>

      {/* Tabs */}
      <Tabs value={activeTab} onValueChange={setActiveTab}>
        <TabsList>
          <TabsTrigger value="locations">Emplacements</TabsTrigger>
          <TabsTrigger value="suggested">
            <Lightbulb className="h-3.5 w-3.5 mr-1" />
            Suggérés
          </TabsTrigger>
        </TabsList>

        <TabsContent value="locations" className="space-y-6 mt-4">
          {/* Filters */}
          <Card>
            <CardContent className="pt-6">
              <div className="flex flex-wrap items-center gap-4">
                <div className="relative flex-1 min-w-[200px]">
                  <Search className="absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-slate-400" />
                  <Input
                    placeholder="Rechercher par nom ou adresse..."
                    value={search}
                    onChange={(e) => setSearch(e.target.value)}
                    className="pl-10"
                  />
                </div>
                <Select value={locationType || 'all'} onValueChange={handleTypeChange}>
                  <SelectTrigger className="w-[180px]">
                    <SelectValue placeholder="Tous les types" />
                  </SelectTrigger>
                  <SelectContent>
                    <SelectItem value="all">Tous les types</SelectItem>
                    {LOCATION_TYPE_VALUES.map((type) => (
                      <SelectItem key={type} value={type}>
                        {LOCATION_TYPE_LABELS[type]}
                      </SelectItem>
                    ))}
                  </SelectContent>
                </Select>
                <Select value={activeFilter} onValueChange={handleActiveChange}>
                  <SelectTrigger className="w-[140px]">
                    <SelectValue placeholder="Statut" />
                  </SelectTrigger>
                  <SelectContent>
                    <SelectItem value="all">Tous les statuts</SelectItem>
                    <SelectItem value="active">Actifs seulement</SelectItem>
                    <SelectItem value="inactive">Inactifs seulement</SelectItem>
                  </SelectContent>
                </Select>
                {hasFilters && (
                  <Button variant="ghost" onClick={handleClearFilters}>
                    <X className="h-4 w-4 mr-2" />
                    Effacer
                  </Button>
                )}
              </div>
            </CardContent>
          </Card>

          {/* Content */}
          {viewMode === 'list' ? (
            <LocationsTable
              locations={locations}
              isLoading={isLoading}
              onView={handleViewLocation}
            />
          ) : (
            <LocationsOverviewMap
              locations={locations}
              isLoading={isLoading}
              onLocationClick={handleViewLocation}
              showInactive={activeFilter !== 'active'}
            />
          )}

          {/* Pagination - only show in list view */}
          {viewMode === 'list' && totalPages > 1 && !isLoading && (
            <div className="flex items-center justify-between">
              <p className="text-sm text-slate-500">
                Affichage {(currentPage - 1) * PAGE_SIZE + 1} à{' '}
                {Math.min(currentPage * PAGE_SIZE, totalCount)} sur {totalCount} emplacements
              </p>
              <Pagination>
                <PaginationContent>
                  <PaginationItem>
                    <PaginationPrevious
                      href="#"
                      onClick={(e) => {
                        e.preventDefault();
                        if (currentPage > 1) setCurrentPage(currentPage - 1);
                      }}
                      className={currentPage <= 1 ? 'pointer-events-none opacity-50' : ''}
                    />
                  </PaginationItem>
                  {pageNumbers.map((page) => (
                    <PaginationItem key={page}>
                      <PaginationLink
                        href="#"
                        onClick={(e) => {
                          e.preventDefault();
                          setCurrentPage(page);
                        }}
                        isActive={page === currentPage}
                      >
                        {page}
                      </PaginationLink>
                    </PaginationItem>
                  ))}
                  <PaginationItem>
                    <PaginationNext
                      href="#"
                      onClick={(e) => {
                        e.preventDefault();
                        if (currentPage < totalPages) setCurrentPage(currentPage + 1);
                      }}
                      className={
                        currentPage >= totalPages ? 'pointer-events-none opacity-50' : ''
                      }
                    />
                  </PaginationItem>
                </PaginationContent>
              </Pagination>
            </div>
          )}
        </TabsContent>

        <TabsContent value="suggested" className="mt-4">
          <SuggestedLocationsTab
            onCreateLocation={(prefill) => {
              setCreatePrefill(prefill);
              setIsCreateDialogOpen(true);
            }}
            locations={activeLocations}
            refreshKey={suggestedRefreshKey}
          />
        </TabsContent>
      </Tabs>

      {/* Create Location Dialog */}
      <Dialog
        open={isCreateDialogOpen}
        onOpenChange={(open) => {
          setIsCreateDialogOpen(open);
          if (!open) setCreatePrefill(null);
        }}
      >
        <DialogContent className="max-w-3xl max-h-[90vh] overflow-y-auto">
          <DialogHeader>
            <DialogTitle>Ajouter un nouvel emplacement</DialogTitle>
            <DialogDescription>
              Créer un nouvel emplacement de travail avec une limite de géorepérage.
            </DialogDescription>
          </DialogHeader>
          <LocationForm
            key={createPrefill ? `prefill-${createPrefill.latitude}-${createPrefill.longitude}` : 'new'}
            prefill={createPrefill}
            onSubmit={handleCreateLocation}
            onCancel={() => setIsCreateDialogOpen(false)}
            isSubmitting={isCreating}
          />
        </DialogContent>
      </Dialog>

      {/* CSV Import Dialog */}
      <CsvImportDialog
        open={isImportDialogOpen}
        onOpenChange={setIsImportDialogOpen}
        onSuccess={() => refetch()}
      />
    </div>
  );
}

interface LocationsTableProps {
  locations: Location[];
  isLoading: boolean;
  onView: (location: Location) => void;
}

function LocationsTable({ locations, isLoading, onView }: LocationsTableProps) {
  if (isLoading) {
    return (
      <Card>
        <CardContent className="p-0">
          <div className="divide-y divide-slate-100">
            {[...Array(5)].map((_, i) => (
              <div key={i} className="flex items-center gap-4 p-4 animate-pulse">
                <div className="h-10 w-10 rounded-full bg-slate-200" />
                <div className="flex-1 space-y-2">
                  <div className="h-4 w-1/3 bg-slate-200 rounded" />
                  <div className="h-3 w-1/2 bg-slate-100 rounded" />
                </div>
              </div>
            ))}
          </div>
        </CardContent>
      </Card>
    );
  }

  if (locations.length === 0) {
    return (
      <Card>
        <CardContent className="flex flex-col items-center justify-center py-12">
          <MapPin className="h-12 w-12 text-slate-300 mb-4" />
          <h3 className="text-lg font-medium text-slate-900 mb-1">
            Aucun emplacement trouvé
          </h3>
          <p className="text-sm text-slate-500">
            Créez votre premier emplacement pour commencer.
          </p>
        </CardContent>
      </Card>
    );
  }

  return (
    <Card>
      <CardContent className="p-0">
        <div className="divide-y divide-slate-100">
          {locations.map((location) => (
            <LocationRow
              key={location.id}
              location={location}
              onClick={() => onView(location)}
            />
          ))}
        </div>
      </CardContent>
    </Card>
  );
}

interface LocationRowProps {
  location: Location;
  onClick: () => void;
}

function LocationRow({ location, onClick }: LocationRowProps) {
  const typeConfig = LOCATION_TYPE_COLORS[location.locationType];

  return (
    <div
      className="flex items-center gap-4 p-4 hover:bg-slate-50 cursor-pointer transition-colors"
      onClick={onClick}
    >
      <div
        className="h-10 w-10 rounded-full flex items-center justify-center text-white"
        style={{ backgroundColor: typeConfig.color }}
      >
        <MapPin className="h-5 w-5" />
      </div>
      <div className="flex-1 min-w-0">
        <div className="flex items-center gap-2">
          <h3 className="font-medium text-slate-900 truncate">{location.name}</h3>
          {!location.isActive && (
            <span className="text-xs px-2 py-0.5 bg-slate-100 text-slate-500 rounded">
              Inactif
            </span>
          )}
        </div>
        <div className="flex items-center gap-3 text-sm text-slate-500">
          <span
            className="px-2 py-0.5 rounded text-xs"
            style={{
              backgroundColor: `${typeConfig.color}15`,
              color: typeConfig.color,
            }}
          >
            {typeConfig.label}
          </span>
          {location.address && (
            <span className="truncate max-w-[300px]">{location.address}</span>
          )}
        </div>
      </div>
      <div className="text-right text-sm text-slate-400">
        <div>{location.radiusMeters}m rayon</div>
        <div className="text-xs">
          Modifié {format(location.updatedAt, 'MMM d, yyyy')}
        </div>
      </div>
    </div>
  );
}
