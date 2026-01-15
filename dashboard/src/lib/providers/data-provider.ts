import { dataProvider as supabaseDataProvider } from '@refinedev/supabase';
import type {
  DataProvider,
  CustomParams,
  CustomResponse,
  BaseRecord,
  GetListParams,
  GetListResponse,
  GetOneParams,
  GetOneResponse,
} from '@refinedev/core';
import { supabaseClient } from '@/lib/supabase/client';

const baseDataProvider = supabaseDataProvider(supabaseClient);

interface RpcMeta {
  rpc?: string;
  rpcParams?: Record<string, unknown>;
}

export const dataProvider: DataProvider = {
  ...baseDataProvider,

  // Extended getList to support RPC-based pagination
  getList: async <TData extends BaseRecord = BaseRecord>(
    params: GetListParams
  ): Promise<GetListResponse<TData>> => {
    const { pagination, filters, sorters, meta } = params;
    const rpcMeta = meta as RpcMeta | undefined;

    // If meta.rpc is provided, use RPC for pagination
    if (rpcMeta?.rpc) {
      const { currentPage = 1, pageSize = 50 } = pagination ?? {};

      // Build RPC parameters
      const rpcParams: Record<string, unknown> = {
        p_limit: pageSize,
        p_offset: (currentPage - 1) * pageSize,
        ...(rpcMeta.rpcParams ?? {}),
      };

      // Convert filters to RPC parameters
      if (filters) {
        for (const filter of filters) {
          if ('field' in filter && filter.value !== undefined && filter.value !== '') {
            // Map common filter fields to RPC parameters
            const paramName = `p_${filter.field}`;
            rpcParams[paramName] = filter.value;
          }
        }
      }

      // Convert sorters to RPC parameters
      if (sorters && sorters.length > 0) {
        const sorter = sorters[0];
        rpcParams.p_sort_field = sorter.field;
        rpcParams.p_sort_order = sorter.order?.toUpperCase() ?? 'ASC';
      }

      const { data, error } = await supabaseClient.rpc(rpcMeta.rpc, rpcParams);
      if (error) throw error;

      // Extract total count from first record if available
      const records = data as Array<TData & { total_count?: number }>;
      const total = records.length > 0 && records[0].total_count != null
        ? Number(records[0].total_count)
        : records.length;

      return {
        data: records as TData[],
        total,
      };
    }

    // Fall back to base data provider
    return baseDataProvider.getList(params);
  },

  // Extended getOne to support RPC-based single record fetch
  getOne: async <TData extends BaseRecord = BaseRecord>(
    params: GetOneParams
  ): Promise<GetOneResponse<TData>> => {
    const { id, meta } = params;
    const rpcMeta = meta as RpcMeta | undefined;

    // If meta.rpc is provided, use RPC for fetching
    if (rpcMeta?.rpc) {
      const rpcParams: Record<string, unknown> = {
        ...(rpcMeta.rpcParams ?? {}),
      };

      // Add the ID parameter (commonly p_employee_id for employee management)
      if (!rpcParams.p_employee_id && id) {
        rpcParams.p_employee_id = id;
      }

      const { data, error } = await supabaseClient.rpc(rpcMeta.rpc, rpcParams);
      if (error) throw error;

      // RPC returns array, get first record
      const records = data as TData[];
      if (!records || records.length === 0) {
        throw new Error('Record not found');
      }

      return { data: records[0] };
    }

    // Fall back to base data provider
    return baseDataProvider.getOne(params);
  },

  custom: async <TData extends BaseRecord = BaseRecord>(params: CustomParams): Promise<CustomResponse<TData>> => {
    const { meta, payload, url, method } = params;
    const rpcMeta = meta as RpcMeta | undefined;

    // Support RPC calls via meta.rpc
    if (rpcMeta?.rpc) {
      const { data, error } = await supabaseClient.rpc(rpcMeta.rpc, payload ?? {});
      if (error) throw error;
      return { data: data as TData };
    }

    // Fall back to base data provider's custom method
    if (baseDataProvider.custom) {
      const result = await baseDataProvider.custom({ url, method, meta, payload });
      return result as CustomResponse<TData>;
    }

    return { data: [] as unknown as TData };
  },
};
