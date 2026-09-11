export type Json =
  | string
  | number
  | boolean
  | null
  | { [key: string]: Json | undefined }
  | Json[]

export type Database = {
  public: {
    Tables: {
      access_grants: {
        Row: {
          company_id: string
          created_at: string
          granted_by: string | null
          id: string
          note: string | null
          person_id: string
          source_preset_id: string | null
          updated_at: string
        }
        Insert: {
          company_id: string
          created_at?: string
          granted_by?: string | null
          id?: string
          note?: string | null
          person_id: string
          source_preset_id?: string | null
          updated_at?: string
        }
        Update: {
          company_id?: string
          created_at?: string
          granted_by?: string | null
          id?: string
          note?: string | null
          person_id?: string
          source_preset_id?: string | null
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "access_grants_company_id_fkey"
            columns: ["company_id"]
            isOneToOne: false
            referencedRelation: "companies"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "access_grants_granted_by_fkey"
            columns: ["granted_by"]
            isOneToOne: false
            referencedRelation: "people"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "access_grants_person_id_fkey"
            columns: ["person_id"]
            isOneToOne: false
            referencedRelation: "people"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "access_grants_source_preset_id_fkey"
            columns: ["source_preset_id"]
            isOneToOne: false
            referencedRelation: "permission_presets"
            referencedColumns: ["id"]
          },
        ]
      }
      activity_log: {
        Row: {
          action: string
          actor_person_id: string | null
          actor_user_id: string | null
          after: Json | null
          at: string
          before: Json | null
          company_id: string | null
          entity_id: string | null
          entity_type: string
          id: number
        }
        Insert: {
          action: string
          actor_person_id?: string | null
          actor_user_id?: string | null
          after?: Json | null
          at?: string
          before?: Json | null
          company_id?: string | null
          entity_id?: string | null
          entity_type: string
          id?: never
        }
        Update: {
          action?: string
          actor_person_id?: string | null
          actor_user_id?: string | null
          after?: Json | null
          at?: string
          before?: Json | null
          company_id?: string | null
          entity_id?: string | null
          entity_type?: string
          id?: never
        }
        Relationships: []
      }
      application_events: {
        Row: {
          actor_id: string | null
          application_id: string
          body: string | null
          created_at: string
          from_stage_key: string | null
          id: string
          kind: string
          to_stage_key: string | null
        }
        Insert: {
          actor_id?: string | null
          application_id: string
          body?: string | null
          created_at?: string
          from_stage_key?: string | null
          id?: string
          kind: string
          to_stage_key?: string | null
        }
        Update: {
          actor_id?: string | null
          application_id?: string
          body?: string | null
          created_at?: string
          from_stage_key?: string | null
          id?: string
          kind?: string
          to_stage_key?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "application_events_actor_id_fkey"
            columns: ["actor_id"]
            isOneToOne: false
            referencedRelation: "people"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "application_events_application_id_fkey"
            columns: ["application_id"]
            isOneToOne: false
            referencedRelation: "applications"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "application_events_from_stage_key_fkey"
            columns: ["from_stage_key"]
            isOneToOne: false
            referencedRelation: "application_stages"
            referencedColumns: ["key"]
          },
          {
            foreignKeyName: "application_events_to_stage_key_fkey"
            columns: ["to_stage_key"]
            isOneToOne: false
            referencedRelation: "application_stages"
            referencedColumns: ["key"]
          },
        ]
      }
      application_stages: {
        Row: {
          is_terminal: boolean
          key: string
          label: string
          sort_order: number
        }
        Insert: {
          is_terminal?: boolean
          key: string
          label: string
          sort_order?: number
        }
        Update: {
          is_terminal?: boolean
          key?: string
          label?: string
          sort_order?: number
        }
        Relationships: []
      }
      applications: {
        Row: {
          candidate_id: string
          company_id: string
          created_at: string
          custom: Json
          employment_period_id: string | null
          id: string
          job_id: string
          next_action: string | null
          next_action_due: string | null
          owner_id: string | null
          provider_ref: string | null
          received_at: string
          rejected_reason: string | null
          source_channel_key: string | null
          source_provider: string | null
          stage_key: string
          updated_at: string
          withdrawn_reason: string | null
        }
        Insert: {
          candidate_id: string
          company_id: string
          created_at?: string
          custom?: Json
          employment_period_id?: string | null
          id?: string
          job_id: string
          next_action?: string | null
          next_action_due?: string | null
          owner_id?: string | null
          provider_ref?: string | null
          received_at?: string
          rejected_reason?: string | null
          source_channel_key?: string | null
          source_provider?: string | null
          stage_key?: string
          updated_at?: string
          withdrawn_reason?: string | null
        }
        Update: {
          candidate_id?: string
          company_id?: string
          created_at?: string
          custom?: Json
          employment_period_id?: string | null
          id?: string
          job_id?: string
          next_action?: string | null
          next_action_due?: string | null
          owner_id?: string | null
          provider_ref?: string | null
          received_at?: string
          rejected_reason?: string | null
          source_channel_key?: string | null
          source_provider?: string | null
          stage_key?: string
          updated_at?: string
          withdrawn_reason?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "applications_candidate_id_fkey"
            columns: ["candidate_id"]
            isOneToOne: false
            referencedRelation: "candidates"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "applications_company_id_fkey"
            columns: ["company_id"]
            isOneToOne: false
            referencedRelation: "companies"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "applications_employment_period_id_fkey"
            columns: ["employment_period_id"]
            isOneToOne: true
            referencedRelation: "employment_periods"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "applications_job_id_fkey"
            columns: ["job_id"]
            isOneToOne: false
            referencedRelation: "jobs"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "applications_owner_id_fkey"
            columns: ["owner_id"]
            isOneToOne: false
            referencedRelation: "people"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "applications_source_channel_key_fkey"
            columns: ["source_channel_key"]
            isOneToOne: false
            referencedRelation: "channels"
            referencedColumns: ["key"]
          },
          {
            foreignKeyName: "applications_stage_key_fkey"
            columns: ["stage_key"]
            isOneToOne: false
            referencedRelation: "application_stages"
            referencedColumns: ["key"]
          },
        ]
      }
      asset_assignments: {
        Row: {
          asset_id: string
          created_at: string
          id: string
          issued_at: string | null
          issued_by: string | null
          note: string | null
          person_id: string
          reserved_at: string | null
          return_condition: string | null
          returned_at: string | null
          updated_at: string
        }
        Insert: {
          asset_id: string
          created_at?: string
          id?: string
          issued_at?: string | null
          issued_by?: string | null
          note?: string | null
          person_id: string
          reserved_at?: string | null
          return_condition?: string | null
          returned_at?: string | null
          updated_at?: string
        }
        Update: {
          asset_id?: string
          created_at?: string
          id?: string
          issued_at?: string | null
          issued_by?: string | null
          note?: string | null
          person_id?: string
          reserved_at?: string | null
          return_condition?: string | null
          returned_at?: string | null
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "asset_assignments_asset_id_fkey"
            columns: ["asset_id"]
            isOneToOne: false
            referencedRelation: "assets"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "asset_assignments_issued_by_fkey"
            columns: ["issued_by"]
            isOneToOne: false
            referencedRelation: "people"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "asset_assignments_person_id_fkey"
            columns: ["person_id"]
            isOneToOne: false
            referencedRelation: "people"
            referencedColumns: ["id"]
          },
        ]
      }
      asset_types: {
        Row: {
          archived_at: string | null
          is_physical: boolean
          key: string
          label: string
        }
        Insert: {
          archived_at?: string | null
          is_physical?: boolean
          key: string
          label: string
        }
        Update: {
          archived_at?: string | null
          is_physical?: boolean
          key?: string
          label?: string
        }
        Relationships: []
      }
      assets: {
        Row: {
          asset_tag: string
          company_id: string
          condition: string | null
          created_at: string
          custom: Json
          id: string
          location_id: string | null
          model: string | null
          note: string | null
          serial_number: string | null
          status: string
          type_key: string
          updated_at: string
        }
        Insert: {
          asset_tag: string
          company_id: string
          condition?: string | null
          created_at?: string
          custom?: Json
          id?: string
          location_id?: string | null
          model?: string | null
          note?: string | null
          serial_number?: string | null
          status?: string
          type_key: string
          updated_at?: string
        }
        Update: {
          asset_tag?: string
          company_id?: string
          condition?: string | null
          created_at?: string
          custom?: Json
          id?: string
          location_id?: string | null
          model?: string | null
          note?: string | null
          serial_number?: string | null
          status?: string
          type_key?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "assets_company_id_fkey"
            columns: ["company_id"]
            isOneToOne: false
            referencedRelation: "companies"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "assets_location_id_fkey"
            columns: ["location_id"]
            isOneToOne: false
            referencedRelation: "locations"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "assets_type_key_fkey"
            columns: ["type_key"]
            isOneToOne: false
            referencedRelation: "asset_types"
            referencedColumns: ["key"]
          },
        ]
      }
      candidates: {
        Row: {
          created_at: string
          custom: Json
          email: string | null
          full_name: string
          id: string
          phone: string | null
          updated_at: string
        }
        Insert: {
          created_at?: string
          custom?: Json
          email?: string | null
          full_name: string
          id?: string
          phone?: string | null
          updated_at?: string
        }
        Update: {
          created_at?: string
          custom?: Json
          email?: string | null
          full_name?: string
          id?: string
          phone?: string | null
          updated_at?: string
        }
        Relationships: []
      }
      capabilities: {
        Row: {
          archived_at: string | null
          group_name: string
          key: string
          label: string
          sensitive: boolean
          sort_order: number
        }
        Insert: {
          archived_at?: string | null
          group_name: string
          key: string
          label: string
          sensitive?: boolean
          sort_order?: number
        }
        Update: {
          archived_at?: string | null
          group_name?: string
          key?: string
          label?: string
          sensitive?: boolean
          sort_order?: number
        }
        Relationships: []
      }
      capability_dependencies: {
        Row: {
          capability_key: string
          requires_key: string
        }
        Insert: {
          capability_key: string
          requires_key: string
        }
        Update: {
          capability_key?: string
          requires_key?: string
        }
        Relationships: [
          {
            foreignKeyName: "capability_dependencies_capability_key_fkey"
            columns: ["capability_key"]
            isOneToOne: false
            referencedRelation: "capabilities"
            referencedColumns: ["key"]
          },
          {
            foreignKeyName: "capability_dependencies_requires_key_fkey"
            columns: ["requires_key"]
            isOneToOne: false
            referencedRelation: "capabilities"
            referencedColumns: ["key"]
          },
        ]
      }
      channels: {
        Row: {
          archived_at: string | null
          key: string
          kind: string
          label: string
        }
        Insert: {
          archived_at?: string | null
          key: string
          kind?: string
          label: string
        }
        Update: {
          archived_at?: string | null
          key?: string
          kind?: string
          label?: string
        }
        Relationships: []
      }
      companies: {
        Row: {
          archived_at: string | null
          brand: Json
          created_at: string
          id: string
          kind: string
          name: string
          parent_company_id: string | null
          settings: Json
          short_code: string
          updated_at: string
        }
        Insert: {
          archived_at?: string | null
          brand?: Json
          created_at?: string
          id?: string
          kind?: string
          name: string
          parent_company_id?: string | null
          settings?: Json
          short_code: string
          updated_at?: string
        }
        Update: {
          archived_at?: string | null
          brand?: Json
          created_at?: string
          id?: string
          kind?: string
          name?: string
          parent_company_id?: string | null
          settings?: Json
          short_code?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "companies_parent_company_id_fkey"
            columns: ["parent_company_id"]
            isOneToOne: false
            referencedRelation: "companies"
            referencedColumns: ["id"]
          },
        ]
      }
      compensation_records: {
        Row: {
          amount: number
          approved_by: string | null
          created_at: string
          currency: string
          effective_date: string
          employment_period_id: string
          end_date: string | null
          id: string
          note: string | null
          pay_basis_key: string
          proposed_by: string | null
          status: string
          updated_at: string
        }
        Insert: {
          amount: number
          approved_by?: string | null
          created_at?: string
          currency: string
          effective_date: string
          employment_period_id: string
          end_date?: string | null
          id?: string
          note?: string | null
          pay_basis_key: string
          proposed_by?: string | null
          status?: string
          updated_at?: string
        }
        Update: {
          amount?: number
          approved_by?: string | null
          created_at?: string
          currency?: string
          effective_date?: string
          employment_period_id?: string
          end_date?: string | null
          id?: string
          note?: string | null
          pay_basis_key?: string
          proposed_by?: string | null
          status?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "compensation_records_approved_by_fkey"
            columns: ["approved_by"]
            isOneToOne: false
            referencedRelation: "people"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "compensation_records_employment_period_id_fkey"
            columns: ["employment_period_id"]
            isOneToOne: false
            referencedRelation: "employment_periods"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "compensation_records_pay_basis_key_fkey"
            columns: ["pay_basis_key"]
            isOneToOne: false
            referencedRelation: "pay_bases"
            referencedColumns: ["key"]
          },
          {
            foreignKeyName: "compensation_records_proposed_by_fkey"
            columns: ["proposed_by"]
            isOneToOne: false
            referencedRelation: "people"
            referencedColumns: ["id"]
          },
        ]
      }
      custom_field_definitions: {
        Row: {
          archived_at: string | null
          company_id: string | null
          entity: string
          field_type: string
          id: string
          key: string
          label: string
          options: Json
          required: boolean
          sort_order: number
        }
        Insert: {
          archived_at?: string | null
          company_id?: string | null
          entity: string
          field_type: string
          id?: string
          key: string
          label: string
          options?: Json
          required?: boolean
          sort_order?: number
        }
        Update: {
          archived_at?: string | null
          company_id?: string | null
          entity?: string
          field_type?: string
          id?: string
          key?: string
          label?: string
          options?: Json
          required?: boolean
          sort_order?: number
        }
        Relationships: [
          {
            foreignKeyName: "custom_field_definitions_company_id_fkey"
            columns: ["company_id"]
            isOneToOne: false
            referencedRelation: "companies"
            referencedColumns: ["id"]
          },
        ]
      }
      departments: {
        Row: {
          archived_at: string | null
          company_id: string | null
          id: string
          name: string
        }
        Insert: {
          archived_at?: string | null
          company_id?: string | null
          id?: string
          name: string
        }
        Update: {
          archived_at?: string | null
          company_id?: string | null
          id?: string
          name?: string
        }
        Relationships: [
          {
            foreignKeyName: "departments_company_id_fkey"
            columns: ["company_id"]
            isOneToOne: false
            referencedRelation: "companies"
            referencedColumns: ["id"]
          },
        ]
      }
      document_categories: {
        Row: {
          archived_at: string | null
          key: string
          label: string
          person_scoped: boolean
          sort_order: number
        }
        Insert: {
          archived_at?: string | null
          key: string
          label: string
          person_scoped?: boolean
          sort_order?: number
        }
        Update: {
          archived_at?: string | null
          key?: string
          label?: string
          person_scoped?: boolean
          sort_order?: number
        }
        Relationships: []
      }
      document_requests: {
        Row: {
          category_key: string
          company_id: string
          created_at: string
          due_date: string | null
          fulfilled_document_id: string | null
          id: string
          note: string | null
          person_id: string
          reviewer_id: string | null
          status: string
          updated_at: string
        }
        Insert: {
          category_key: string
          company_id: string
          created_at?: string
          due_date?: string | null
          fulfilled_document_id?: string | null
          id?: string
          note?: string | null
          person_id: string
          reviewer_id?: string | null
          status?: string
          updated_at?: string
        }
        Update: {
          category_key?: string
          company_id?: string
          created_at?: string
          due_date?: string | null
          fulfilled_document_id?: string | null
          id?: string
          note?: string | null
          person_id?: string
          reviewer_id?: string | null
          status?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "document_requests_category_key_fkey"
            columns: ["category_key"]
            isOneToOne: false
            referencedRelation: "document_categories"
            referencedColumns: ["key"]
          },
          {
            foreignKeyName: "document_requests_company_id_fkey"
            columns: ["company_id"]
            isOneToOne: false
            referencedRelation: "companies"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "document_requests_fulfilled_document_id_fkey"
            columns: ["fulfilled_document_id"]
            isOneToOne: false
            referencedRelation: "documents"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "document_requests_person_id_fkey"
            columns: ["person_id"]
            isOneToOne: false
            referencedRelation: "people"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "document_requests_reviewer_id_fkey"
            columns: ["reviewer_id"]
            isOneToOne: false
            referencedRelation: "people"
            referencedColumns: ["id"]
          },
        ]
      }
      documents: {
        Row: {
          archived_at: string | null
          category_key: string
          company_id: string
          created_at: string
          id: string
          person_id: string | null
          storage_path: string
          supersedes_id: string | null
          title: string
          uploaded_by: string | null
          version: number
          visibility: string
        }
        Insert: {
          archived_at?: string | null
          category_key: string
          company_id: string
          created_at?: string
          id?: string
          person_id?: string | null
          storage_path: string
          supersedes_id?: string | null
          title: string
          uploaded_by?: string | null
          version?: number
          visibility?: string
        }
        Update: {
          archived_at?: string | null
          category_key?: string
          company_id?: string
          created_at?: string
          id?: string
          person_id?: string | null
          storage_path?: string
          supersedes_id?: string | null
          title?: string
          uploaded_by?: string | null
          version?: number
          visibility?: string
        }
        Relationships: [
          {
            foreignKeyName: "documents_category_key_fkey"
            columns: ["category_key"]
            isOneToOne: false
            referencedRelation: "document_categories"
            referencedColumns: ["key"]
          },
          {
            foreignKeyName: "documents_company_id_fkey"
            columns: ["company_id"]
            isOneToOne: false
            referencedRelation: "companies"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "documents_person_id_fkey"
            columns: ["person_id"]
            isOneToOne: false
            referencedRelation: "people"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "documents_supersedes_id_fkey"
            columns: ["supersedes_id"]
            isOneToOne: false
            referencedRelation: "documents"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "documents_uploaded_by_fkey"
            columns: ["uploaded_by"]
            isOneToOne: false
            referencedRelation: "people"
            referencedColumns: ["id"]
          },
        ]
      }
      employment_departure_details: {
        Row: {
          employment_period_id: string
          reason: string | null
          recorded_at: string
          recorded_by: string | null
        }
        Insert: {
          employment_period_id: string
          reason?: string | null
          recorded_at?: string
          recorded_by?: string | null
        }
        Update: {
          employment_period_id?: string
          reason?: string | null
          recorded_at?: string
          recorded_by?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "employment_departure_details_employment_period_id_fkey"
            columns: ["employment_period_id"]
            isOneToOne: true
            referencedRelation: "employment_periods"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "employment_departure_details_recorded_by_fkey"
            columns: ["recorded_by"]
            isOneToOne: false
            referencedRelation: "people"
            referencedColumns: ["id"]
          },
        ]
      }
      employment_periods: {
        Row: {
          company_id: string
          created_at: string
          custom: Json
          department_id: string | null
          employment_type_key: string | null
          end_date: string | null
          id: string
          job_title: string
          last_working_date: string | null
          location_id: string | null
          manager_id: string | null
          person_id: string
          start_date: string
          status: string
          updated_at: string
        }
        Insert: {
          company_id: string
          created_at?: string
          custom?: Json
          department_id?: string | null
          employment_type_key?: string | null
          end_date?: string | null
          id?: string
          job_title: string
          last_working_date?: string | null
          location_id?: string | null
          manager_id?: string | null
          person_id: string
          start_date: string
          status?: string
          updated_at?: string
        }
        Update: {
          company_id?: string
          created_at?: string
          custom?: Json
          department_id?: string | null
          employment_type_key?: string | null
          end_date?: string | null
          id?: string
          job_title?: string
          last_working_date?: string | null
          location_id?: string | null
          manager_id?: string | null
          person_id?: string
          start_date?: string
          status?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "employment_periods_company_id_fkey"
            columns: ["company_id"]
            isOneToOne: false
            referencedRelation: "companies"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "employment_periods_department_id_fkey"
            columns: ["department_id"]
            isOneToOne: false
            referencedRelation: "departments"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "employment_periods_employment_type_key_fkey"
            columns: ["employment_type_key"]
            isOneToOne: false
            referencedRelation: "employment_types"
            referencedColumns: ["key"]
          },
          {
            foreignKeyName: "employment_periods_location_id_fkey"
            columns: ["location_id"]
            isOneToOne: false
            referencedRelation: "locations"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "employment_periods_manager_id_fkey"
            columns: ["manager_id"]
            isOneToOne: false
            referencedRelation: "people"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "employment_periods_person_id_fkey"
            columns: ["person_id"]
            isOneToOne: false
            referencedRelation: "people"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "employment_periods_status_fkey"
            columns: ["status"]
            isOneToOne: false
            referencedRelation: "employment_statuses"
            referencedColumns: ["key"]
          },
        ]
      }
      employment_statuses: {
        Row: {
          counts_as_employed: boolean
          key: string
          label: string
          sort_order: number
        }
        Insert: {
          counts_as_employed?: boolean
          key: string
          label: string
          sort_order?: number
        }
        Update: {
          counts_as_employed?: boolean
          key?: string
          label?: string
          sort_order?: number
        }
        Relationships: []
      }
      employment_types: {
        Row: {
          archived_at: string | null
          key: string
          label: string
          required_fields: Json
          sort_order: number
        }
        Insert: {
          archived_at?: string | null
          key: string
          label: string
          required_fields?: Json
          sort_order?: number
        }
        Update: {
          archived_at?: string | null
          key?: string
          label?: string
          required_fields?: Json
          sort_order?: number
        }
        Relationships: []
      }
      external_project_members: {
        Row: {
          external_ref: string | null
          id: string
          last_synced_at: string
          person_id: string
          project_id: string
          role: string | null
        }
        Insert: {
          external_ref?: string | null
          id?: string
          last_synced_at?: string
          person_id: string
          project_id: string
          role?: string | null
        }
        Update: {
          external_ref?: string | null
          id?: string
          last_synced_at?: string
          person_id?: string
          project_id?: string
          role?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "external_project_members_person_id_fkey"
            columns: ["person_id"]
            isOneToOne: false
            referencedRelation: "people"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "external_project_members_project_id_fkey"
            columns: ["project_id"]
            isOneToOne: false
            referencedRelation: "external_projects"
            referencedColumns: ["id"]
          },
        ]
      }
      external_projects: {
        Row: {
          company_id: string
          external_id: string
          id: string
          last_synced_at: string
          name: string
          provider_key: string
          raw: Json
          status: string | null
          url: string | null
        }
        Insert: {
          company_id: string
          external_id: string
          id?: string
          last_synced_at?: string
          name: string
          provider_key: string
          raw?: Json
          status?: string | null
          url?: string | null
        }
        Update: {
          company_id?: string
          external_id?: string
          id?: string
          last_synced_at?: string
          name?: string
          provider_key?: string
          raw?: Json
          status?: string | null
          url?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "external_projects_company_id_fkey"
            columns: ["company_id"]
            isOneToOne: false
            referencedRelation: "companies"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "external_projects_provider_key_fkey"
            columns: ["provider_key"]
            isOneToOne: false
            referencedRelation: "providers"
            referencedColumns: ["key"]
          },
        ]
      }
      grant_capabilities: {
        Row: {
          capability_key: string
          grant_id: string
        }
        Insert: {
          capability_key: string
          grant_id: string
        }
        Update: {
          capability_key?: string
          grant_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "grant_capabilities_capability_key_fkey"
            columns: ["capability_key"]
            isOneToOne: false
            referencedRelation: "capabilities"
            referencedColumns: ["key"]
          },
          {
            foreignKeyName: "grant_capabilities_grant_id_fkey"
            columns: ["grant_id"]
            isOneToOne: false
            referencedRelation: "access_grants"
            referencedColumns: ["id"]
          },
        ]
      }
      hiring_requests: {
        Row: {
          budget: Json | null
          change_reason: string | null
          company_id: string
          created_at: string
          custom: Json
          decided_at: string | null
          decided_by: string | null
          headcount: number
          hiring_manager_id: string | null
          id: string
          reason: string | null
          requested_by: string | null
          status: string
          target_start_date: string | null
          title: string
          updated_at: string
        }
        Insert: {
          budget?: Json | null
          change_reason?: string | null
          company_id: string
          created_at?: string
          custom?: Json
          decided_at?: string | null
          decided_by?: string | null
          headcount?: number
          hiring_manager_id?: string | null
          id?: string
          reason?: string | null
          requested_by?: string | null
          status?: string
          target_start_date?: string | null
          title: string
          updated_at?: string
        }
        Update: {
          budget?: Json | null
          change_reason?: string | null
          company_id?: string
          created_at?: string
          custom?: Json
          decided_at?: string | null
          decided_by?: string | null
          headcount?: number
          hiring_manager_id?: string | null
          id?: string
          reason?: string | null
          requested_by?: string | null
          status?: string
          target_start_date?: string | null
          title?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "hiring_requests_company_id_fkey"
            columns: ["company_id"]
            isOneToOne: false
            referencedRelation: "companies"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "hiring_requests_decided_by_fkey"
            columns: ["decided_by"]
            isOneToOne: false
            referencedRelation: "people"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "hiring_requests_hiring_manager_id_fkey"
            columns: ["hiring_manager_id"]
            isOneToOne: false
            referencedRelation: "people"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "hiring_requests_requested_by_fkey"
            columns: ["requested_by"]
            isOneToOne: false
            referencedRelation: "people"
            referencedColumns: ["id"]
          },
        ]
      }
      integrations: {
        Row: {
          authorized_by: string | null
          company_id: string
          config: Json
          created_at: string
          external_org_id: string | null
          id: string
          last_error: string | null
          last_sync_at: string | null
          provider_key: string
          status: string
          updated_at: string
        }
        Insert: {
          authorized_by?: string | null
          company_id: string
          config?: Json
          created_at?: string
          external_org_id?: string | null
          id?: string
          last_error?: string | null
          last_sync_at?: string | null
          provider_key: string
          status?: string
          updated_at?: string
        }
        Update: {
          authorized_by?: string | null
          company_id?: string
          config?: Json
          created_at?: string
          external_org_id?: string | null
          id?: string
          last_error?: string | null
          last_sync_at?: string | null
          provider_key?: string
          status?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "integrations_authorized_by_fkey"
            columns: ["authorized_by"]
            isOneToOne: false
            referencedRelation: "people"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "integrations_company_id_fkey"
            columns: ["company_id"]
            isOneToOne: false
            referencedRelation: "companies"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "integrations_provider_key_fkey"
            columns: ["provider_key"]
            isOneToOne: false
            referencedRelation: "providers"
            referencedColumns: ["key"]
          },
        ]
      }
      it_requests: {
        Row: {
          assignee_id: string | null
          blocked_reason: string | null
          company_id: string
          created_at: string
          due_at: string | null
          id: string
          kind: string
          person_id: string
          plan_task_id: string | null
          requested_by: string | null
          requested_systems: Json
          status: string
          title: string
          updated_at: string
        }
        Insert: {
          assignee_id?: string | null
          blocked_reason?: string | null
          company_id: string
          created_at?: string
          due_at?: string | null
          id?: string
          kind?: string
          person_id: string
          plan_task_id?: string | null
          requested_by?: string | null
          requested_systems?: Json
          status?: string
          title: string
          updated_at?: string
        }
        Update: {
          assignee_id?: string | null
          blocked_reason?: string | null
          company_id?: string
          created_at?: string
          due_at?: string | null
          id?: string
          kind?: string
          person_id?: string
          plan_task_id?: string | null
          requested_by?: string | null
          requested_systems?: Json
          status?: string
          title?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "it_requests_assignee_id_fkey"
            columns: ["assignee_id"]
            isOneToOne: false
            referencedRelation: "people"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "it_requests_company_id_fkey"
            columns: ["company_id"]
            isOneToOne: false
            referencedRelation: "companies"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "it_requests_person_id_fkey"
            columns: ["person_id"]
            isOneToOne: false
            referencedRelation: "people"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "it_requests_plan_task_id_fkey"
            columns: ["plan_task_id"]
            isOneToOne: false
            referencedRelation: "plan_tasks"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "it_requests_requested_by_fkey"
            columns: ["requested_by"]
            isOneToOne: false
            referencedRelation: "people"
            referencedColumns: ["id"]
          },
        ]
      }
      job_channels: {
        Row: {
          channel_key: string
          external_job_id: string | null
          id: string
          job_id: string
          last_error: string | null
          publication_url: string | null
          published_by: string | null
          published_revision: number | null
          status: string
          updated_at: string
          verified_by: string | null
        }
        Insert: {
          channel_key: string
          external_job_id?: string | null
          id?: string
          job_id: string
          last_error?: string | null
          publication_url?: string | null
          published_by?: string | null
          published_revision?: number | null
          status?: string
          updated_at?: string
          verified_by?: string | null
        }
        Update: {
          channel_key?: string
          external_job_id?: string | null
          id?: string
          job_id?: string
          last_error?: string | null
          publication_url?: string | null
          published_by?: string | null
          published_revision?: number | null
          status?: string
          updated_at?: string
          verified_by?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "job_channels_channel_key_fkey"
            columns: ["channel_key"]
            isOneToOne: false
            referencedRelation: "channels"
            referencedColumns: ["key"]
          },
          {
            foreignKeyName: "job_channels_job_id_fkey"
            columns: ["job_id"]
            isOneToOne: false
            referencedRelation: "jobs"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "job_channels_published_by_fkey"
            columns: ["published_by"]
            isOneToOne: false
            referencedRelation: "people"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "job_channels_verified_by_fkey"
            columns: ["verified_by"]
            isOneToOne: false
            referencedRelation: "people"
            referencedColumns: ["id"]
          },
        ]
      }
      jobs: {
        Row: {
          company_id: string
          created_at: string
          custom: Json
          description: string | null
          description_revision: number
          hiring_request_id: string | null
          id: string
          screening_questions: Json
          status: string
          title: string
          updated_at: string
        }
        Insert: {
          company_id: string
          created_at?: string
          custom?: Json
          description?: string | null
          description_revision?: number
          hiring_request_id?: string | null
          id?: string
          screening_questions?: Json
          status?: string
          title: string
          updated_at?: string
        }
        Update: {
          company_id?: string
          created_at?: string
          custom?: Json
          description?: string | null
          description_revision?: number
          hiring_request_id?: string | null
          id?: string
          screening_questions?: Json
          status?: string
          title?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "jobs_company_id_fkey"
            columns: ["company_id"]
            isOneToOne: false
            referencedRelation: "companies"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "jobs_hiring_request_id_fkey"
            columns: ["hiring_request_id"]
            isOneToOne: false
            referencedRelation: "hiring_requests"
            referencedColumns: ["id"]
          },
        ]
      }
      leave_links: {
        Row: {
          external_employee_id: string
          id: string
          last_status: string | null
          last_synced_at: string | null
          person_id: string
          provider_key: string
          sync_error: string | null
          updated_at: string
        }
        Insert: {
          external_employee_id: string
          id?: string
          last_status?: string | null
          last_synced_at?: string | null
          person_id: string
          provider_key: string
          sync_error?: string | null
          updated_at?: string
        }
        Update: {
          external_employee_id?: string
          id?: string
          last_status?: string | null
          last_synced_at?: string | null
          person_id?: string
          provider_key?: string
          sync_error?: string | null
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "leave_links_person_id_fkey"
            columns: ["person_id"]
            isOneToOne: true
            referencedRelation: "people"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "leave_links_provider_key_fkey"
            columns: ["provider_key"]
            isOneToOne: false
            referencedRelation: "providers"
            referencedColumns: ["key"]
          },
        ]
      }
      locations: {
        Row: {
          archived_at: string | null
          company_id: string | null
          country_code: string | null
          id: string
          name: string
        }
        Insert: {
          archived_at?: string | null
          company_id?: string | null
          country_code?: string | null
          id?: string
          name: string
        }
        Update: {
          archived_at?: string | null
          company_id?: string | null
          country_code?: string | null
          id?: string
          name?: string
        }
        Relationships: [
          {
            foreignKeyName: "locations_company_id_fkey"
            columns: ["company_id"]
            isOneToOne: false
            referencedRelation: "companies"
            referencedColumns: ["id"]
          },
        ]
      }
      offers: {
        Row: {
          accepted_at: string | null
          application_id: string
          approved_by: string | null
          company_id: string
          created_at: string
          id: string
          status: string
          terms: Json
          updated_at: string
        }
        Insert: {
          accepted_at?: string | null
          application_id: string
          approved_by?: string | null
          company_id: string
          created_at?: string
          id?: string
          status?: string
          terms?: Json
          updated_at?: string
        }
        Update: {
          accepted_at?: string | null
          application_id?: string
          approved_by?: string | null
          company_id?: string
          created_at?: string
          id?: string
          status?: string
          terms?: Json
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "offers_application_id_fkey"
            columns: ["application_id"]
            isOneToOne: false
            referencedRelation: "applications"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "offers_approved_by_fkey"
            columns: ["approved_by"]
            isOneToOne: false
            referencedRelation: "people"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "offers_company_id_fkey"
            columns: ["company_id"]
            isOneToOne: false
            referencedRelation: "companies"
            referencedColumns: ["id"]
          },
        ]
      }
      pay_bases: {
        Row: {
          key: string
          label: string
          sort_order: number
        }
        Insert: {
          key: string
          label: string
          sort_order?: number
        }
        Update: {
          key?: string
          label?: string
          sort_order?: number
        }
        Relationships: []
      }
      payroll_periods: {
        Row: {
          approved_by: string | null
          company_id: string
          created_at: string
          currency: string
          export_document_id: string | null
          exported_at: string | null
          id: string
          note: string | null
          period_end: string
          period_start: string
          status: string
          updated_at: string
        }
        Insert: {
          approved_by?: string | null
          company_id: string
          created_at?: string
          currency: string
          export_document_id?: string | null
          exported_at?: string | null
          id?: string
          note?: string | null
          period_end: string
          period_start: string
          status?: string
          updated_at?: string
        }
        Update: {
          approved_by?: string | null
          company_id?: string
          created_at?: string
          currency?: string
          export_document_id?: string | null
          exported_at?: string | null
          id?: string
          note?: string | null
          period_end?: string
          period_start?: string
          status?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "payroll_periods_approved_by_fkey"
            columns: ["approved_by"]
            isOneToOne: false
            referencedRelation: "people"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "payroll_periods_company_id_fkey"
            columns: ["company_id"]
            isOneToOne: false
            referencedRelation: "companies"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "payroll_periods_export_document_id_fkey"
            columns: ["export_document_id"]
            isOneToOne: false
            referencedRelation: "documents"
            referencedColumns: ["id"]
          },
        ]
      }
      people: {
        Row: {
          archived_at: string | null
          avatar_url: string | null
          created_at: string
          custom: Json
          full_name: string
          id: string
          personal_email: string | null
          phone: string | null
          preferred_name: string | null
          updated_at: string
          user_id: string | null
          work_email: string | null
        }
        Insert: {
          archived_at?: string | null
          avatar_url?: string | null
          created_at?: string
          custom?: Json
          full_name: string
          id?: string
          personal_email?: string | null
          phone?: string | null
          preferred_name?: string | null
          updated_at?: string
          user_id?: string | null
          work_email?: string | null
        }
        Update: {
          archived_at?: string | null
          avatar_url?: string | null
          created_at?: string
          custom?: Json
          full_name?: string
          id?: string
          personal_email?: string | null
          phone?: string | null
          preferred_name?: string | null
          updated_at?: string
          user_id?: string | null
          work_email?: string | null
        }
        Relationships: []
      }
      permission_presets: {
        Row: {
          archived_at: string | null
          company_id: string | null
          description: string | null
          id: string
          is_system: boolean
          name: string
        }
        Insert: {
          archived_at?: string | null
          company_id?: string | null
          description?: string | null
          id?: string
          is_system?: boolean
          name: string
        }
        Update: {
          archived_at?: string | null
          company_id?: string | null
          description?: string | null
          id?: string
          is_system?: boolean
          name?: string
        }
        Relationships: [
          {
            foreignKeyName: "permission_presets_company_id_fkey"
            columns: ["company_id"]
            isOneToOne: false
            referencedRelation: "companies"
            referencedColumns: ["id"]
          },
        ]
      }
      person_private_details: {
        Row: {
          address: Json | null
          birth_date: string | null
          custom: Json
          emergency_contacts: Json
          national_id_hint: string | null
          notes: string | null
          person_id: string
          updated_at: string
        }
        Insert: {
          address?: Json | null
          birth_date?: string | null
          custom?: Json
          emergency_contacts?: Json
          national_id_hint?: string | null
          notes?: string | null
          person_id: string
          updated_at?: string
        }
        Update: {
          address?: Json | null
          birth_date?: string | null
          custom?: Json
          emergency_contacts?: Json
          national_id_hint?: string | null
          notes?: string | null
          person_id?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "person_private_details_person_id_fkey"
            columns: ["person_id"]
            isOneToOne: true
            referencedRelation: "people"
            referencedColumns: ["id"]
          },
        ]
      }
      plan_phases: {
        Row: {
          key: string
          label: string
          sort_order: number
        }
        Insert: {
          key: string
          label: string
          sort_order?: number
        }
        Update: {
          key?: string
          label?: string
          sort_order?: number
        }
        Relationships: []
      }
      plan_tasks: {
        Row: {
          blocked_reason: string | null
          critical: boolean
          description: string | null
          done_at: string | null
          done_by: string | null
          due_date: string | null
          evidence_document_id: string | null
          id: string
          owner_id: string | null
          owner_role: string
          phase_key: string
          plan_id: string
          requires_evidence: boolean
          skip_reason: string | null
          sort_order: number
          status: string
          template_task_id: string | null
          title: string
          updated_at: string
        }
        Insert: {
          blocked_reason?: string | null
          critical?: boolean
          description?: string | null
          done_at?: string | null
          done_by?: string | null
          due_date?: string | null
          evidence_document_id?: string | null
          id?: string
          owner_id?: string | null
          owner_role?: string
          phase_key: string
          plan_id: string
          requires_evidence?: boolean
          skip_reason?: string | null
          sort_order?: number
          status?: string
          template_task_id?: string | null
          title: string
          updated_at?: string
        }
        Update: {
          blocked_reason?: string | null
          critical?: boolean
          description?: string | null
          done_at?: string | null
          done_by?: string | null
          due_date?: string | null
          evidence_document_id?: string | null
          id?: string
          owner_id?: string | null
          owner_role?: string
          phase_key?: string
          plan_id?: string
          requires_evidence?: boolean
          skip_reason?: string | null
          sort_order?: number
          status?: string
          template_task_id?: string | null
          title?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "plan_tasks_done_by_fkey"
            columns: ["done_by"]
            isOneToOne: false
            referencedRelation: "people"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "plan_tasks_evidence_fk"
            columns: ["evidence_document_id"]
            isOneToOne: false
            referencedRelation: "documents"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "plan_tasks_owner_id_fkey"
            columns: ["owner_id"]
            isOneToOne: false
            referencedRelation: "people"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "plan_tasks_phase_key_fkey"
            columns: ["phase_key"]
            isOneToOne: false
            referencedRelation: "plan_phases"
            referencedColumns: ["key"]
          },
          {
            foreignKeyName: "plan_tasks_plan_id_fkey"
            columns: ["plan_id"]
            isOneToOne: false
            referencedRelation: "plans"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "plan_tasks_template_task_id_fkey"
            columns: ["template_task_id"]
            isOneToOne: false
            referencedRelation: "template_tasks"
            referencedColumns: ["id"]
          },
        ]
      }
      plans: {
        Row: {
          cancelled_reason: string | null
          company_id: string
          completed_at: string | null
          created_at: string
          employment_period_id: string | null
          hr_owner_id: string | null
          id: string
          kind: string
          person_id: string
          start_date: string
          status: string
          template_id: string | null
          updated_at: string
        }
        Insert: {
          cancelled_reason?: string | null
          company_id: string
          completed_at?: string | null
          created_at?: string
          employment_period_id?: string | null
          hr_owner_id?: string | null
          id?: string
          kind: string
          person_id: string
          start_date: string
          status?: string
          template_id?: string | null
          updated_at?: string
        }
        Update: {
          cancelled_reason?: string | null
          company_id?: string
          completed_at?: string | null
          created_at?: string
          employment_period_id?: string | null
          hr_owner_id?: string | null
          id?: string
          kind?: string
          person_id?: string
          start_date?: string
          status?: string
          template_id?: string | null
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "plans_company_id_fkey"
            columns: ["company_id"]
            isOneToOne: false
            referencedRelation: "companies"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "plans_employment_period_id_fkey"
            columns: ["employment_period_id"]
            isOneToOne: false
            referencedRelation: "employment_periods"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "plans_hr_owner_id_fkey"
            columns: ["hr_owner_id"]
            isOneToOne: false
            referencedRelation: "people"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "plans_person_id_fkey"
            columns: ["person_id"]
            isOneToOne: false
            referencedRelation: "people"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "plans_template_id_fkey"
            columns: ["template_id"]
            isOneToOne: false
            referencedRelation: "task_templates"
            referencedColumns: ["id"]
          },
        ]
      }
      platform_admins: {
        Row: {
          granted_at: string
          granted_by: string | null
          person_id: string
        }
        Insert: {
          granted_at?: string
          granted_by?: string | null
          person_id: string
        }
        Update: {
          granted_at?: string
          granted_by?: string | null
          person_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "platform_admins_granted_by_fkey"
            columns: ["granted_by"]
            isOneToOne: false
            referencedRelation: "people"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "platform_admins_person_id_fkey"
            columns: ["person_id"]
            isOneToOne: true
            referencedRelation: "people"
            referencedColumns: ["id"]
          },
        ]
      }
      policies: {
        Row: {
          company_id: string | null
          created_at: string
          id: string
          published_at: string | null
          published_by: string | null
          status: string
          storage_path: string | null
          title: string
          updated_at: string
          version: number
        }
        Insert: {
          company_id?: string | null
          created_at?: string
          id?: string
          published_at?: string | null
          published_by?: string | null
          status?: string
          storage_path?: string | null
          title: string
          updated_at?: string
          version?: number
        }
        Update: {
          company_id?: string | null
          created_at?: string
          id?: string
          published_at?: string | null
          published_by?: string | null
          status?: string
          storage_path?: string | null
          title?: string
          updated_at?: string
          version?: number
        }
        Relationships: [
          {
            foreignKeyName: "policies_company_id_fkey"
            columns: ["company_id"]
            isOneToOne: false
            referencedRelation: "companies"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "policies_published_by_fkey"
            columns: ["published_by"]
            isOneToOne: false
            referencedRelation: "people"
            referencedColumns: ["id"]
          },
        ]
      }
      policy_acknowledgements: {
        Row: {
          acknowledged_at: string
          id: string
          person_id: string
          policy_id: string
          version: number
        }
        Insert: {
          acknowledged_at?: string
          id?: string
          person_id: string
          policy_id: string
          version: number
        }
        Update: {
          acknowledged_at?: string
          id?: string
          person_id?: string
          policy_id?: string
          version?: number
        }
        Relationships: [
          {
            foreignKeyName: "policy_acknowledgements_person_id_fkey"
            columns: ["person_id"]
            isOneToOne: false
            referencedRelation: "people"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "policy_acknowledgements_policy_id_fkey"
            columns: ["policy_id"]
            isOneToOne: false
            referencedRelation: "policies"
            referencedColumns: ["id"]
          },
        ]
      }
      preset_capabilities: {
        Row: {
          capability_key: string
          preset_id: string
        }
        Insert: {
          capability_key: string
          preset_id: string
        }
        Update: {
          capability_key?: string
          preset_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "preset_capabilities_capability_key_fkey"
            columns: ["capability_key"]
            isOneToOne: false
            referencedRelation: "capabilities"
            referencedColumns: ["key"]
          },
          {
            foreignKeyName: "preset_capabilities_preset_id_fkey"
            columns: ["preset_id"]
            isOneToOne: false
            referencedRelation: "permission_presets"
            referencedColumns: ["id"]
          },
        ]
      }
      promotions: {
        Row: {
          brief: Json
          channel_key: string
          company_id: string
          copy: string | null
          created_at: string
          creative_document_id: string | null
          deadline: string | null
          id: string
          job_id: string
          publication_url: string | null
          published_by: string | null
          requested_by: string | null
          reviewed_by: string | null
          status: string
          updated_at: string
        }
        Insert: {
          brief?: Json
          channel_key?: string
          company_id: string
          copy?: string | null
          created_at?: string
          creative_document_id?: string | null
          deadline?: string | null
          id?: string
          job_id: string
          publication_url?: string | null
          published_by?: string | null
          requested_by?: string | null
          reviewed_by?: string | null
          status?: string
          updated_at?: string
        }
        Update: {
          brief?: Json
          channel_key?: string
          company_id?: string
          copy?: string | null
          created_at?: string
          creative_document_id?: string | null
          deadline?: string | null
          id?: string
          job_id?: string
          publication_url?: string | null
          published_by?: string | null
          requested_by?: string | null
          reviewed_by?: string | null
          status?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "promotions_channel_key_fkey"
            columns: ["channel_key"]
            isOneToOne: false
            referencedRelation: "channels"
            referencedColumns: ["key"]
          },
          {
            foreignKeyName: "promotions_company_id_fkey"
            columns: ["company_id"]
            isOneToOne: false
            referencedRelation: "companies"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "promotions_creative_fk"
            columns: ["creative_document_id"]
            isOneToOne: false
            referencedRelation: "documents"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "promotions_job_id_fkey"
            columns: ["job_id"]
            isOneToOne: false
            referencedRelation: "jobs"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "promotions_published_by_fkey"
            columns: ["published_by"]
            isOneToOne: false
            referencedRelation: "people"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "promotions_requested_by_fkey"
            columns: ["requested_by"]
            isOneToOne: false
            referencedRelation: "people"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "promotions_reviewed_by_fkey"
            columns: ["reviewed_by"]
            isOneToOne: false
            referencedRelation: "people"
            referencedColumns: ["id"]
          },
        ]
      }
      providers: {
        Row: {
          archived_at: string | null
          key: string
          kind: string
          label: string
        }
        Insert: {
          archived_at?: string | null
          key: string
          kind: string
          label: string
        }
        Update: {
          archived_at?: string | null
          key?: string
          kind?: string
          label?: string
        }
        Relationships: []
      }
      task_templates: {
        Row: {
          active: boolean
          company_id: string | null
          created_at: string
          id: string
          kind: string
          name: string
          updated_at: string
        }
        Insert: {
          active?: boolean
          company_id?: string | null
          created_at?: string
          id?: string
          kind: string
          name: string
          updated_at?: string
        }
        Update: {
          active?: boolean
          company_id?: string | null
          created_at?: string
          id?: string
          kind?: string
          name?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "task_templates_company_id_fkey"
            columns: ["company_id"]
            isOneToOne: false
            referencedRelation: "companies"
            referencedColumns: ["id"]
          },
        ]
      }
      template_tasks: {
        Row: {
          critical: boolean
          default_owner_role: string
          description: string | null
          due_offset_days: number
          id: string
          phase_key: string
          requires_evidence: boolean
          sort_order: number
          template_id: string
          title: string
        }
        Insert: {
          critical?: boolean
          default_owner_role?: string
          description?: string | null
          due_offset_days?: number
          id?: string
          phase_key: string
          requires_evidence?: boolean
          sort_order?: number
          template_id: string
          title: string
        }
        Update: {
          critical?: boolean
          default_owner_role?: string
          description?: string | null
          due_offset_days?: number
          id?: string
          phase_key?: string
          requires_evidence?: boolean
          sort_order?: number
          template_id?: string
          title?: string
        }
        Relationships: [
          {
            foreignKeyName: "template_tasks_phase_key_fkey"
            columns: ["phase_key"]
            isOneToOne: false
            referencedRelation: "plan_phases"
            referencedColumns: ["key"]
          },
          {
            foreignKeyName: "template_tasks_template_id_fkey"
            columns: ["template_id"]
            isOneToOne: false
            referencedRelation: "task_templates"
            referencedColumns: ["id"]
          },
        ]
      }
      workflow_owners: {
        Row: {
          company_id: string
          id: string
          person_id: string | null
          role_key: string
          updated_at: string
        }
        Insert: {
          company_id: string
          id?: string
          person_id?: string | null
          role_key: string
          updated_at?: string
        }
        Update: {
          company_id?: string
          id?: string
          person_id?: string | null
          role_key?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "workflow_owners_company_id_fkey"
            columns: ["company_id"]
            isOneToOne: false
            referencedRelation: "companies"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "workflow_owners_person_id_fkey"
            columns: ["person_id"]
            isOneToOne: false
            referencedRelation: "people"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "workflow_owners_role_key_fkey"
            columns: ["role_key"]
            isOneToOne: false
            referencedRelation: "workflow_roles"
            referencedColumns: ["key"]
          },
        ]
      }
      workflow_roles: {
        Row: {
          key: string
          label: string
        }
        Insert: {
          key: string
          label: string
        }
        Update: {
          key?: string
          label?: string
        }
        Relationships: []
      }
    }
    Views: {
      [_ in never]: never
    }
    Functions: {
      [_ in never]: never
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
  TableName extends (DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof (DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"] &
        DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Views"])
    : never) = never,
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
  TableName extends (DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
    : never) = never,
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
  TableName extends (DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
    : never) = never,
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
  EnumName extends (DefaultSchemaEnumNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaEnumNameOrOptions["schema"]]["Enums"]
    : never) = never,
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
  CompositeTypeName extends (PublicCompositeTypeNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[PublicCompositeTypeNameOrOptions["schema"]]["CompositeTypes"]
    : never) = never,
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

