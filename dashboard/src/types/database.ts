export type Json =
  | string
  | number
  | boolean
  | null
  | { [key: string]: Json | undefined }
  | Json[]

export type Database = {
  // Allows to automatically instantiate createClient with right options
  // instead of createClient<Database, { PostgrestVersion: 'XX' }>(URL, KEY)
  __InternalSupabase: {
    PostgrestVersion: "14.1"
  }
  public: {
    Tables: {
      employee_profiles: {
        Row: {
          created_at: string
          email: string
          employee_id: string | null
          full_name: string | null
          id: string
          privacy_consent_at: string | null
          role: string
          status: string
          updated_at: string
        }
        Insert: {
          created_at?: string
          email: string
          employee_id?: string | null
          full_name?: string | null
          id: string
          privacy_consent_at?: string | null
          role?: string
          status?: string
          updated_at?: string
        }
        Update: {
          created_at?: string
          email?: string
          employee_id?: string | null
          full_name?: string | null
          id?: string
          privacy_consent_at?: string | null
          role?: string
          status?: string
          updated_at?: string
        }
        Relationships: []
      }
      employee_supervisors: {
        Row: {
          created_at: string
          effective_from: string
          effective_to: string | null
          employee_id: string
          id: string
          manager_id: string
          supervision_type: string
        }
        Insert: {
          created_at?: string
          effective_from?: string
          effective_to?: string | null
          employee_id: string
          id?: string
          manager_id: string
          supervision_type?: string
        }
        Update: {
          created_at?: string
          effective_from?: string
          effective_to?: string | null
          employee_id?: string
          id?: string
          manager_id?: string
          supervision_type?: string
        }
        Relationships: [
          {
            foreignKeyName: "employee_supervisors_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "employee_profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "employee_supervisors_manager_id_fkey"
            columns: ["manager_id"]
            isOneToOne: false
            referencedRelation: "employee_profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      gps_points: {
        Row: {
          accuracy: number | null
          captured_at: string
          client_id: string
          created_at: string
          device_id: string | null
          employee_id: string
          id: string
          latitude: number
          longitude: number
          received_at: string
          shift_id: string
        }
        Insert: {
          accuracy?: number | null
          captured_at: string
          client_id: string
          created_at?: string
          device_id?: string | null
          employee_id: string
          id?: string
          latitude: number
          longitude: number
          received_at?: string
          shift_id: string
        }
        Update: {
          accuracy?: number | null
          captured_at?: string
          client_id?: string
          created_at?: string
          device_id?: string | null
          employee_id?: string
          id?: string
          latitude?: number
          longitude?: number
          received_at?: string
          shift_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "gps_points_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "employee_profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "gps_points_shift_id_fkey"
            columns: ["shift_id"]
            isOneToOne: false
            referencedRelation: "shifts"
            referencedColumns: ["id"]
          },
        ]
      }
      shifts: {
        Row: {
          clock_in_accuracy: number | null
          clock_in_location: Json | null
          clock_out_accuracy: number | null
          clock_out_location: Json | null
          clocked_in_at: string
          clocked_out_at: string | null
          created_at: string
          employee_id: string
          id: string
          request_id: string | null
          status: string
          updated_at: string
        }
        Insert: {
          clock_in_accuracy?: number | null
          clock_in_location?: Json | null
          clock_out_accuracy?: number | null
          clock_out_location?: Json | null
          clocked_in_at?: string
          clocked_out_at?: string | null
          created_at?: string
          employee_id: string
          id?: string
          request_id?: string | null
          status?: string
          updated_at?: string
        }
        Update: {
          clock_in_accuracy?: number | null
          clock_in_location?: Json | null
          clock_out_accuracy?: number | null
          clock_out_location?: Json | null
          clocked_in_at?: string
          clocked_out_at?: string | null
          created_at?: string
          employee_id?: string
          id?: string
          request_id?: string | null
          status?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "shifts_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "employee_profiles"
            referencedColumns: ["id"]
          },
        ]
      }
    }
    Views: {
      [_ in never]: never
    }
    Functions: {
      clock_in: {
        Args: { p_accuracy?: number; p_location?: Json; p_request_id: string }
        Returns: Json
      }
      clock_out: {
        Args: {
          p_accuracy?: number
          p_location?: Json
          p_request_id: string
          p_shift_id: string
        }
        Returns: Json
      }
      get_dashboard_summary: {
        Args: {
          p_include_recent_shifts?: boolean
          p_recent_shifts_limit?: number
        }
        Returns: Json
      }
      get_employee_shifts: {
        Args: {
          p_employee_id: string
          p_end_date?: string
          p_limit?: number
          p_offset?: number
          p_start_date?: string
        }
        Returns: {
          clock_in_accuracy: number
          clock_in_location: Json
          clock_out_accuracy: number
          clock_out_location: Json
          clocked_in_at: string
          clocked_out_at: string
          created_at: string
          duration_seconds: number
          employee_id: string
          gps_point_count: number
          id: string
          status: string
        }[]
      }
      get_employee_statistics: {
        Args: {
          p_employee_id: string
          p_end_date?: string
          p_start_date?: string
        }
        Returns: {
          avg_duration_seconds: number
          earliest_shift: string
          latest_shift: string
          total_gps_points: number
          total_seconds: number
          total_shifts: number
        }[]
      }
      get_shift_gps_points: {
        Args: { p_shift_id: string }
        Returns: {
          accuracy: number
          captured_at: string
          id: string
          latitude: number
          longitude: number
        }[]
      }
      get_supervised_employees: {
        Args: never
        Returns: {
          email: string
          employee_id: string
          full_name: string
          id: string
          last_shift_at: string
          role: string
          status: string
          total_hours_this_month: number
          total_shifts_this_month: number
        }[]
      }
      get_team_active_status: {
        Args: never
        Returns: {
          current_shift_started_at: string
          display_name: string
          email: string
          employee_id: string
          employee_number: string
          is_active: boolean
          monthly_hours_seconds: number
          monthly_shift_count: number
          today_hours_seconds: number
        }[]
      }
      get_team_employee_hours: {
        Args: { p_end_date?: string; p_start_date?: string }
        Returns: {
          display_name: string
          employee_id: string
          total_hours: number
        }[]
      }
      get_team_statistics: {
        Args: { p_end_date?: string; p_start_date?: string }
        Returns: {
          avg_duration_seconds: number
          avg_shifts_per_employee: number
          total_employees: number
          total_seconds: number
          total_shifts: number
        }[]
      }
      sync_gps_points: { Args: { p_points: Json }; Returns: Json }
      // New dashboard functions (from migration 010)
      get_org_dashboard_summary: {
        Args: Record<string, never>
        Returns: Json
      }
      get_manager_team_summaries: {
        Args: { p_start_date?: string; p_end_date?: string }
        Returns: {
          manager_id: string
          manager_name: string
          manager_email: string
          team_size: number
          active_employees: number
          total_hours: number
          total_shifts: number
          avg_hours_per_employee: number
        }[]
      }
    }
    Enums: {
      [_ in never]: never
    }
    CompositeTypes: {
      [_ in never]: never
    }
  }
}

type DatabaseWithoutInternals = Omit<Database, "__InternalSupabase">

type DefaultSchema = DatabaseWithoutInternals[Extract<keyof Database, "public">]

export type Tables<
  DefaultSchemaTableNameOrOptions extends
    | keyof (DefaultSchema["Tables"] & DefaultSchema["Views"])
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof (DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"] &
        DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Views"])
    : never = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? (DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"] &
      DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Views"])[TableName] extends {
      Row: infer R
    }
    ? R
    : never
  : DefaultSchemaTableNameOrOptions extends keyof (DefaultSchema["Tables"] &
        DefaultSchema["Views"])
    ? (DefaultSchema["Tables"] &
        DefaultSchema["Views"])[DefaultSchemaTableNameOrOptions] extends {
        Row: infer R
      }
      ? R
      : never
    : never

export type TablesInsert<
  DefaultSchemaTableNameOrOptions extends
    | keyof DefaultSchema["Tables"]
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
    : never = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"][TableName] extends {
      Insert: infer I
    }
    ? I
    : never
  : DefaultSchemaTableNameOrOptions extends keyof DefaultSchema["Tables"]
    ? DefaultSchema["Tables"][DefaultSchemaTableNameOrOptions] extends {
        Insert: infer I
      }
      ? I
      : never
    : never

export type TablesUpdate<
  DefaultSchemaTableNameOrOptions extends
    | keyof DefaultSchema["Tables"]
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
    : never = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"][TableName] extends {
      Update: infer U
    }
    ? U
    : never
  : DefaultSchemaTableNameOrOptions extends keyof DefaultSchema["Tables"]
    ? DefaultSchema["Tables"][DefaultSchemaTableNameOrOptions] extends {
        Update: infer U
      }
      ? U
      : never
    : never

export type Enums<
  DefaultSchemaEnumNameOrOptions extends
    | keyof DefaultSchema["Enums"]
    | { schema: keyof DatabaseWithoutInternals },
  EnumName extends DefaultSchemaEnumNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaEnumNameOrOptions["schema"]]["Enums"]
    : never = never,
> = DefaultSchemaEnumNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaEnumNameOrOptions["schema"]]["Enums"][EnumName]
  : DefaultSchemaEnumNameOrOptions extends keyof DefaultSchema["Enums"]
    ? DefaultSchema["Enums"][DefaultSchemaEnumNameOrOptions]
    : never

export type CompositeTypes<
  PublicCompositeTypeNameOrOptions extends
    | keyof DefaultSchema["CompositeTypes"]
    | { schema: keyof DatabaseWithoutInternals },
  CompositeTypeName extends PublicCompositeTypeNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[PublicCompositeTypeNameOrOptions["schema"]]["CompositeTypes"]
    : never = never,
> = PublicCompositeTypeNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[PublicCompositeTypeNameOrOptions["schema"]]["CompositeTypes"][CompositeTypeName]
  : PublicCompositeTypeNameOrOptions extends keyof DefaultSchema["CompositeTypes"]
    ? DefaultSchema["CompositeTypes"][PublicCompositeTypeNameOrOptions]
    : never

export const Constants = {
  public: {
    Enums: {},
  },
} as const
