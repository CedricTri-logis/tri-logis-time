import { dataProvider as supabaseDataProvider } from '@refinedev/supabase';
import type { DataProvider, CustomParams, CustomResponse, BaseRecord } from '@refinedev/core';
import { supabaseClient } from '@/lib/supabase/client';

const baseDataProvider = supabaseDataProvider(supabaseClient);

interface RpcMeta {
  rpc?: string;
}

export const dataProvider: DataProvider = {
  ...baseDataProvider,

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
