'use client';

import { useState, useEffect, useCallback } from 'react';
import { workforceClient } from '@/lib/supabase/client';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from '@/components/ui/select';
import { Label } from '@/components/ui/label';
import { Building, Loader2 } from 'lucide-react';
import { toast } from 'sonner';

interface BuildingLinkSectionProps {
  locationId: string;
}

interface BuildingOption {
  id: string;
  name: string;
  location_id: string | null;
}

export function BuildingLinkSection({ locationId }: BuildingLinkSectionProps) {
  const [cleaningBuildings, setCleaningBuildings] = useState<BuildingOption[]>([]);
  const [propertyBuildings, setPropertyBuildings] = useState<BuildingOption[]>([]);
  const [linkedCleaning, setLinkedCleaning] = useState<string>('none');
  const [linkedProperty, setLinkedProperty] = useState<string>('none');
  const [isLoading, setIsLoading] = useState(true);

  const fetchData = useCallback(async () => {
    setIsLoading(true);
    const [{ data: cb }, { data: pb }] = await Promise.all([
      workforceClient().from('buildings').select('id, name, location_id').order('name'),
      workforceClient().from('property_buildings').select('id, name, location_id').order('name'),
    ]);
    setCleaningBuildings(cb ?? []);
    setPropertyBuildings(pb ?? []);
    setLinkedCleaning(cb?.find((b) => b.location_id === locationId)?.id ?? 'none');
    setLinkedProperty(pb?.find((b) => b.location_id === locationId)?.id ?? 'none');
    setIsLoading(false);
  }, [locationId]);

  useEffect(() => { fetchData(); }, [fetchData]);

  const handleCleaningChange = useCallback(async (buildingId: string) => {
    // Unlink previous
    if (linkedCleaning !== 'none') {
      await workforceClient().from('buildings').update({ location_id: null }).eq('id', linkedCleaning);
    }
    // Link new
    if (buildingId !== 'none') {
      const { error } = await workforceClient().from('buildings').update({ location_id: locationId }).eq('id', buildingId);
      if (error) { toast.error('Erreur'); return; }
    }
    setLinkedCleaning(buildingId);
    toast.success('Building menage mis a jour');
  }, [locationId, linkedCleaning]);

  const handlePropertyChange = useCallback(async (buildingId: string) => {
    if (linkedProperty !== 'none') {
      await workforceClient().from('property_buildings').update({ location_id: null }).eq('id', linkedProperty);
    }
    if (buildingId !== 'none') {
      const { error } = await workforceClient().from('property_buildings').update({ location_id: locationId }).eq('id', buildingId);
      if (error) { toast.error('Erreur'); return; }
    }
    setLinkedProperty(buildingId);
    toast.success('Building maintenance mis à jour');
  }, [locationId, linkedProperty]);

  if (isLoading) return <Card><CardContent className="py-6"><Loader2 className="h-4 w-4 animate-spin" /></CardContent></Card>;

  return (
    <Card>
      <CardHeader>
        <CardTitle className="text-base flex items-center gap-2">
          <Building className="h-4 w-4" />
          Buildings lies
        </CardTitle>
      </CardHeader>
      <CardContent className="space-y-4">
        <div className="space-y-2">
          <Label>Building menage (cleaning)</Label>
          <Select value={linkedCleaning} onValueChange={handleCleaningChange}>
            <SelectTrigger><SelectValue placeholder="Aucun" /></SelectTrigger>
            <SelectContent>
              <SelectItem value="none">Aucun</SelectItem>
              {cleaningBuildings
                .filter((b) => b.location_id === null || b.location_id === locationId)
                .map((b) => (
                  <SelectItem key={b.id} value={b.id}>{b.name}</SelectItem>
                ))}
            </SelectContent>
          </Select>
        </div>
        <div className="space-y-2">
          <Label>Building maintenance (property)</Label>
          <Select value={linkedProperty} onValueChange={handlePropertyChange}>
            <SelectTrigger><SelectValue placeholder="Aucun" /></SelectTrigger>
            <SelectContent>
              <SelectItem value="none">Aucun</SelectItem>
              {propertyBuildings
                .filter((b) => b.location_id === null || b.location_id === locationId)
                .map((b) => (
                  <SelectItem key={b.id} value={b.id}>{b.name}</SelectItem>
                ))}
            </SelectContent>
          </Select>
        </div>
      </CardContent>
    </Card>
  );
}
