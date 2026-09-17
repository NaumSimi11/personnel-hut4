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
        Relationships: [
          {
            foreignKeyName: "activity_log_actor_person_id_fkey"
            columns: ["actor_person_id"]
            isOneToOne: false
            referencedRelation: "people"
            referencedColumns: ["id"]
          },
        ]
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
      application_files: {
        Row: {
          application_id: string
          company_id: string
          created_at: string
          extracted_text: string | null
          id: string
          kind: string
          mime_type: string
          original_name: string
          size_bytes: number
          storage_path: string
          uploaded_by: string | null
        }
        Insert: {
          application_id: string
          company_id: string
          created_at?: string
          extracted_text?: string | null
          id?: string
          kind?: string
          mime_type: string
          original_name: string
          size_bytes: number
          storage_path: string
          uploaded_by?: string | null
        }
        Update: {
          application_id?: string
          company_id?: string
          created_at?: string
          extracted_text?: string | null
          id?: string
          kind?: string
          mime_type?: string
          original_name?: string
          size_bytes?: number
          storage_path?: string
          uploaded_by?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "application_files_application_id_fkey"
            columns: ["application_id"]
            isOneToOne: false
            referencedRelation: "applications"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "application_files_company_id_fkey"
            columns: ["company_id"]
            isOneToOne: false
            referencedRelation: "companies"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "application_files_uploaded_by_fkey"
            columns: ["uploaded_by"]
            isOneToOne: false
            referencedRelation: "people"
            referencedColumns: ["id"]
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
          screening_answers: Json
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
          screening_answers?: Json
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
          screening_answers?: Json
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
          company_id: string | null
          condition: string | null
          created_at: string
          custom: Json
          holder_note: string | null
          id: string
          inventory_number: string | null
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
          company_id: string | null
          condition?: string | null
          created_at?: string
          custom?: Json
          holder_note?: string | null
          id?: string
          inventory_number?: string | null
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
          company_id?: string | null
          condition?: string | null
          created_at?: string
          custom?: Json
          holder_note?: string | null
          id?: string
          inventory_number?: string | null
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
          address_line1: string | null
          address_line2: string | null
          archived_at: string | null
          brand: Json
          city: string | null
          contact_email: string | null
          contact_phone: string | null
          country: string | null
          country_code: string | null
          created_at: string
          director_person_id: string | null
          hr_contact_person_id: string | null
          hr_notification_email: string | null
          it_notification_email: string | null
          id: string
          kind: string
          leave_carry_over_until: string
          leave_entitlement_days: number
          legal_name: string | null
          name: string
          parent_company_id: string | null
          postcode: string | null
          registration_number: string | null
          settings: Json
          short_code: string
          tax_id: string | null
          updated_at: string
          website: string | null
        }
        Insert: {
          address_line1?: string | null
          address_line2?: string | null
          archived_at?: string | null
          brand?: Json
          city?: string | null
          contact_email?: string | null
          contact_phone?: string | null
          country?: string | null
          country_code?: string | null
          created_at?: string
          director_person_id?: string | null
          hr_contact_person_id?: string | null
          hr_notification_email?: string | null
          it_notification_email?: string | null
          id?: string
          kind?: string
          leave_carry_over_until?: string
          leave_entitlement_days?: number
          legal_name?: string | null
          name: string
          parent_company_id?: string | null
          postcode?: string | null
          registration_number?: string | null
          settings?: Json
          short_code: string
          tax_id?: string | null
          updated_at?: string
          website?: string | null
        }
        Update: {
          address_line1?: string | null
          address_line2?: string | null
          archived_at?: string | null
          brand?: Json
          city?: string | null
          contact_email?: string | null
          contact_phone?: string | null
          country?: string | null
          country_code?: string | null
          created_at?: string
          director_person_id?: string | null
          hr_contact_person_id?: string | null
          hr_notification_email?: string | null
          it_notification_email?: string | null
          id?: string
          kind?: string
          leave_carry_over_until?: string
          leave_entitlement_days?: number
          legal_name?: string | null
          name?: string
          parent_company_id?: string | null
          postcode?: string | null
          registration_number?: string | null
          settings?: Json
          short_code?: string
          tax_id?: string | null
          updated_at?: string
          website?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "companies_director_person_id_fkey"
            columns: ["director_person_id"]
            isOneToOne: false
            referencedRelation: "people"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "companies_hr_contact_person_id_fkey"
            columns: ["hr_contact_person_id"]
            isOneToOne: false
            referencedRelation: "people"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "companies_parent_company_id_fkey"
            columns: ["parent_company_id"]
            isOneToOne: false
            referencedRelation: "companies"
            referencedColumns: ["id"]
          },
        ]
      }
      company_closures: {
        Row: {
          company_id: string
          created_at: string
          date: string
          id: string
          name: string
        }
        Insert: {
          company_id: string
          created_at?: string
          date: string
          id?: string
          name: string
        }
        Update: {
          company_id?: string
          created_at?: string
          date?: string
          id?: string
          name?: string
        }
        Relationships: [
          {
            foreignKeyName: "company_closures_company_id_fkey"
            columns: ["company_id"]
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
          mime_type: string | null
          note: string | null
          original_name: string | null
          person_id: string | null
          size_bytes: number | null
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
          mime_type?: string | null
          note?: string | null
          original_name?: string | null
          person_id?: string | null
          size_bytes?: number | null
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
          mime_type?: string | null
          note?: string | null
          original_name?: string | null
          person_id?: string | null
          size_bytes?: number | null
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
      employment_changes: {
        Row: {
          applied_at: string | null
          changes: Json
          company_id: string
          created_at: string
          created_by: string | null
          effective_date: string
          employment_period_id: string
          failure_reason: string | null
          id: string
          reason: string | null
          status: string
        }
        Insert: {
          applied_at?: string | null
          changes: Json
          company_id: string
          created_at?: string
          created_by?: string | null
          effective_date: string
          employment_period_id: string
          failure_reason?: string | null
          id?: string
          reason?: string | null
          status?: string
        }
        Update: {
          applied_at?: string | null
          changes?: Json
          company_id?: string
          created_at?: string
          created_by?: string | null
          effective_date?: string
          employment_period_id?: string
          failure_reason?: string | null
          id?: string
          reason?: string | null
          status?: string
        }
        Relationships: [
          {
            foreignKeyName: "employment_changes_company_id_fkey"
            columns: ["company_id"]
            isOneToOne: false
            referencedRelation: "companies"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "employment_changes_created_by_fkey"
            columns: ["created_by"]
            isOneToOne: false
            referencedRelation: "people"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "employment_changes_employment_period_id_fkey"
            columns: ["employment_period_id"]
            isOneToOne: false
            referencedRelation: "employment_periods"
            referencedColumns: ["id"]
          },
        ]
      }
      employment_corrections: {
        Row: {
          company_id: string
          corrected_at: string
          corrected_by: string | null
          id: string
          new_department_id: string | null
          new_location_id: string | null
          new_manager_id: string | null
          old_department_id: string | null
          old_location_id: string | null
          old_manager_id: string | null
          new_employment_type_key: string | null
          new_job_title: string
          new_start_date: string
          old_employment_type_key: string | null
          old_job_title: string
          old_start_date: string
          period_id: string
          person_id: string
          reason: string | null
        }
        Insert: {
          company_id: string
          corrected_at?: string
          corrected_by?: string | null
          id?: string
          new_department_id?: string | null
          new_location_id?: string | null
          new_manager_id?: string | null
          old_department_id?: string | null
          old_location_id?: string | null
          old_manager_id?: string | null
          new_employment_type_key?: string | null
          new_job_title: string
          new_start_date: string
          old_employment_type_key?: string | null
          old_job_title: string
          old_start_date: string
          period_id: string
          person_id: string
          reason?: string | null
        }
        Update: {
          company_id?: string
          corrected_at?: string
          corrected_by?: string | null
          id?: string
          new_department_id?: string | null
          new_location_id?: string | null
          new_manager_id?: string | null
          old_department_id?: string | null
          old_location_id?: string | null
          old_manager_id?: string | null
          new_employment_type_key?: string | null
          new_job_title?: string
          new_start_date?: string
          old_employment_type_key?: string | null
          old_job_title?: string
          old_start_date?: string
          period_id?: string
          person_id?: string
          reason?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "employment_corrections_company_id_fkey"
            columns: ["company_id"]
            isOneToOne: false
            referencedRelation: "companies"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "employment_corrections_corrected_by_fkey"
            columns: ["corrected_by"]
            isOneToOne: false
            referencedRelation: "people"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "employment_corrections_period_id_fkey"
            columns: ["period_id"]
            isOneToOne: false
            referencedRelation: "employment_periods"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "employment_corrections_person_id_fkey"
            columns: ["person_id"]
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
          transferred_to_period_id: string | null
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
          transferred_to_period_id?: string | null
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
          transferred_to_period_id?: string | null
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
          {
            foreignKeyName: "employment_periods_transferred_to_period_id_fkey"
            columns: ["transferred_to_period_id"]
            isOneToOne: false
            referencedRelation: "employment_periods"
            referencedColumns: ["id"]
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
      generated_documents: {
        Row: {
          attempts: number
          company_id: string
          created_at: string
          dedupe_key: string
          document_id: string | null
          error: string | null
          id: string
          kind: string
          person_id: string
          plan_id: string | null
          requested_by: string | null
          status: string
          updated_at: string
        }
        Insert: {
          attempts?: number
          company_id: string
          created_at?: string
          dedupe_key: string
          document_id?: string | null
          error?: string | null
          id?: string
          kind: string
          person_id: string
          plan_id?: string | null
          requested_by?: string | null
          status?: string
          updated_at?: string
        }
        Update: {
          attempts?: number
          company_id?: string
          created_at?: string
          dedupe_key?: string
          document_id?: string | null
          error?: string | null
          id?: string
          kind?: string
          person_id?: string
          plan_id?: string | null
          requested_by?: string | null
          status?: string
          updated_at?: string
        }
        Relationships: []
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
      hiring_request_history: {
        Row: {
          actor_id: string | null
          at: string
          company_id: string
          id: string
          kind: string
          reason: string | null
          request_id: string
          snapshot: Json
        }
        Insert: {
          actor_id?: string | null
          at?: string
          company_id: string
          id?: string
          kind: string
          reason?: string | null
          request_id: string
          snapshot: Json
        }
        Update: {
          actor_id?: string | null
          at?: string
          company_id?: string
          id?: string
          kind?: string
          reason?: string | null
          request_id?: string
          snapshot?: Json
        }
        Relationships: [
          {
            foreignKeyName: "hiring_request_history_actor_id_fkey"
            columns: ["actor_id"]
            isOneToOne: false
            referencedRelation: "people"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "hiring_request_history_company_id_fkey"
            columns: ["company_id"]
            isOneToOne: false
            referencedRelation: "companies"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "hiring_request_history_request_id_fkey"
            columns: ["request_id"]
            isOneToOne: false
            referencedRelation: "hiring_requests"
            referencedColumns: ["id"]
          },
        ]
      }
      handover_recipients: {
        Row: {
          active: boolean
          company_id: string | null
          created_at: string
          email: string | null
          events: string[]
          fields: string[]
          id: string
          kind: string
          label: string
          person_id: string | null
          role_key: string | null
          sort_order: number
          trusted: boolean
          updated_at: string
        }
        Insert: {
          active?: boolean
          company_id?: string | null
          created_at?: string
          email?: string | null
          events?: string[]
          fields?: string[]
          id?: string
          kind: string
          label: string
          person_id?: string | null
          role_key?: string | null
          sort_order?: number
          trusted?: boolean
          updated_at?: string
        }
        Update: {
          active?: boolean
          company_id?: string | null
          created_at?: string
          email?: string | null
          events?: string[]
          fields?: string[]
          id?: string
          kind?: string
          label?: string
          person_id?: string | null
          role_key?: string | null
          sort_order?: number
          trusted?: boolean
          updated_at?: string
        }
        Relationships: []
      }
      handover_sends: {
        Row: {
          attempts: number
          company_id: string
          created_at: string
          dedupe_key: string
          employment_period_id: string | null
          error: string | null
          event: string
          fields: Json
          id: string
          marked_by: string | null
          missing: string[]
          person_id: string
          plan_id: string | null
          recipient_id: string | null
          recipient_label: string
          sent_at: string | null
          status: string
          stripped: string[]
          to_email: string | null
          updated_at: string
        }
        Insert: {
          attempts?: number
          company_id: string
          created_at?: string
          dedupe_key: string
          employment_period_id?: string | null
          error?: string | null
          event: string
          fields?: Json
          id?: string
          marked_by?: string | null
          missing?: string[]
          person_id: string
          plan_id?: string | null
          recipient_id?: string | null
          recipient_label: string
          sent_at?: string | null
          status?: string
          stripped?: string[]
          to_email?: string | null
          updated_at?: string
        }
        Update: {
          attempts?: number
          company_id?: string
          created_at?: string
          dedupe_key?: string
          employment_period_id?: string | null
          error?: string | null
          event?: string
          fields?: Json
          id?: string
          marked_by?: string | null
          missing?: string[]
          person_id?: string
          plan_id?: string | null
          recipient_id?: string | null
          recipient_label?: string
          sent_at?: string | null
          status?: string
          stripped?: string[]
          to_email?: string | null
          updated_at?: string
        }
        Relationships: []
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
      interview_panel: {
        Row: {
          interview_id: string
          person_id: string
        }
        Insert: {
          interview_id: string
          person_id: string
        }
        Update: {
          interview_id?: string
          person_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "interview_panel_interview_id_fkey"
            columns: ["interview_id"]
            isOneToOne: false
            referencedRelation: "interviews"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "interview_panel_person_id_fkey"
            columns: ["person_id"]
            isOneToOne: false
            referencedRelation: "people"
            referencedColumns: ["id"]
          },
        ]
      }
      interviews: {
        Row: {
          application_id: string
          company_id: string
          created_at: string
          created_by: string | null
          duration_minutes: number
          id: string
          kind: string
          location: string | null
          notes: string | null
          scheduled_at: string
          status: string
          updated_at: string
        }
        Insert: {
          application_id: string
          company_id: string
          created_at?: string
          created_by?: string | null
          duration_minutes?: number
          id?: string
          kind?: string
          location?: string | null
          notes?: string | null
          scheduled_at: string
          status?: string
          updated_at?: string
        }
        Update: {
          application_id?: string
          company_id?: string
          created_at?: string
          created_by?: string | null
          duration_minutes?: number
          id?: string
          kind?: string
          location?: string | null
          notes?: string | null
          scheduled_at?: string
          status?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "interviews_application_id_fkey"
            columns: ["application_id"]
            isOneToOne: false
            referencedRelation: "applications"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "interviews_company_id_fkey"
            columns: ["company_id"]
            isOneToOne: false
            referencedRelation: "companies"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "interviews_created_by_fkey"
            columns: ["created_by"]
            isOneToOne: false
            referencedRelation: "people"
            referencedColumns: ["id"]
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
          scorecard_criteria: Json
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
          scorecard_criteria?: Json
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
          scorecard_criteria?: Json
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
      kudos: {
        Row: {
          created_at: string
          from_person_id: string
          id: string
          message: string
          posted_by: string | null
          to_person_id: string
          value_id: string | null
        }
        Insert: {
          created_at?: string
          from_person_id: string
          id?: string
          message: string
          posted_by?: string | null
          to_person_id: string
          value_id?: string | null
        }
        Update: {
          created_at?: string
          from_person_id?: string
          id?: string
          message?: string
          posted_by?: string | null
          to_person_id?: string
          value_id?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "kudos_from_person_id_fkey"
            columns: ["from_person_id"]
            isOneToOne: false
            referencedRelation: "people"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "kudos_to_person_id_fkey"
            columns: ["to_person_id"]
            isOneToOne: false
            referencedRelation: "people"
            referencedColumns: ["id"]
          },
        ]
      }
      kudos_values: {
        Row: {
          active: boolean
          created_at: string
          description: string | null
          id: string
          name: string
          sort_order: number
        }
        Insert: {
          active?: boolean
          created_at?: string
          description?: string | null
          id?: string
          name: string
          sort_order?: number
        }
        Update: {
          active?: boolean
          created_at?: string
          description?: string | null
          id?: string
          name?: string
          sort_order?: number
        }
        Relationships: []
      }
      leave_adjustments: {
        Row: {
          balance_id: string
          company_id: string
          created_at: string
          created_by: string | null
          days: number
          id: string
          kind: string
          reason: string
        }
        Insert: {
          balance_id: string
          company_id: string
          created_at?: string
          created_by?: string | null
          days: number
          id?: string
          kind: string
          reason: string
        }
        Update: {
          balance_id?: string
          company_id?: string
          created_at?: string
          created_by?: string | null
          days?: number
          id?: string
          kind?: string
          reason?: string
        }
        Relationships: [
          {
            foreignKeyName: "leave_adjustments_balance_id_fkey"
            columns: ["balance_id"]
            isOneToOne: false
            referencedRelation: "leave_balances"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "leave_adjustments_company_id_fkey"
            columns: ["company_id"]
            isOneToOne: false
            referencedRelation: "companies"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "leave_adjustments_created_by_fkey"
            columns: ["created_by"]
            isOneToOne: false
            referencedRelation: "people"
            referencedColumns: ["id"]
          },
        ]
      }
      leave_balances: {
        Row: {
          carry_over_days: number
          carry_over_expires_on: string | null
          company_id: string
          created_at: string
          entitlement_days: number
          id: string
          person_id: string
          updated_at: string
          year: number
        }
        Insert: {
          carry_over_days?: number
          carry_over_expires_on?: string | null
          company_id: string
          created_at?: string
          entitlement_days?: number
          id?: string
          person_id: string
          updated_at?: string
          year: number
        }
        Update: {
          carry_over_days?: number
          carry_over_expires_on?: string | null
          company_id?: string
          created_at?: string
          entitlement_days?: number
          id?: string
          person_id?: string
          updated_at?: string
          year?: number
        }
        Relationships: [
          {
            foreignKeyName: "leave_balances_company_id_fkey"
            columns: ["company_id"]
            isOneToOne: false
            referencedRelation: "companies"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "leave_balances_person_id_fkey"
            columns: ["person_id"]
            isOneToOne: false
            referencedRelation: "people"
            referencedColumns: ["id"]
          },
        ]
      }
      leave_corrections: {
        Row: {
          company_id: string
          corrected_at: string
          corrected_by: string | null
          id: string
          new_end: string
          new_leave_type_key: string
          new_start: string
          new_working_days: number
          note: string | null
          old_end: string
          old_leave_type_key: string
          old_start: string
          old_working_days: number
          person_id: string
          request_id: string
          split_request_ids: string[]
        }
        Insert: {
          company_id: string
          corrected_at?: string
          corrected_by?: string | null
          id?: string
          new_end: string
          new_leave_type_key: string
          new_start: string
          new_working_days: number
          note?: string | null
          old_end: string
          old_leave_type_key: string
          old_start: string
          old_working_days: number
          person_id: string
          request_id: string
          split_request_ids?: string[]
        }
        Update: {
          company_id?: string
          corrected_at?: string
          corrected_by?: string | null
          id?: string
          new_end?: string
          new_leave_type_key?: string
          new_start?: string
          new_working_days?: number
          note?: string | null
          old_end?: string
          old_leave_type_key?: string
          old_start?: string
          old_working_days?: number
          person_id?: string
          request_id?: string
          split_request_ids?: string[]
        }
        Relationships: [
          {
            foreignKeyName: "leave_corrections_company_id_fkey"
            columns: ["company_id"]
            isOneToOne: false
            referencedRelation: "companies"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "leave_corrections_corrected_by_fkey"
            columns: ["corrected_by"]
            isOneToOne: false
            referencedRelation: "people"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "leave_corrections_person_id_fkey"
            columns: ["person_id"]
            isOneToOne: false
            referencedRelation: "people"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "leave_corrections_request_id_fkey"
            columns: ["request_id"]
            isOneToOne: false
            referencedRelation: "leave_requests"
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
      leave_request_documents: {
        Row: {
          document_id: string
          request_id: string
        }
        Insert: {
          document_id: string
          request_id: string
        }
        Update: {
          document_id?: string
          request_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "leave_request_documents_document_id_fkey"
            columns: ["document_id"]
            isOneToOne: false
            referencedRelation: "documents"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "leave_request_documents_request_id_fkey"
            columns: ["request_id"]
            isOneToOne: false
            referencedRelation: "leave_requests"
            referencedColumns: ["id"]
          },
        ]
      }
      leave_requests: {
        Row: {
          cancellation_decline_note: string | null
          cancellation_declined_at: string | null
          cancellation_declined_by: string | null
          cancellation_reason: string | null
          cancellation_request_reason: string | null
          cancellation_requested_at: string | null
          cancelled_at: string | null
          cancelled_by: string | null
          carry_over_days_used: number
          company_id: string
          corrected_from_id: string | null
          created_at: string
          decided_at: string | null
          decided_by: string | null
          decision_note: string | null
          deducts_balance: boolean
          documents_to_follow: boolean
          employment_period_id: string
          end_date: string
          id: string
          leave_type_key: string
          legacy_id: number | null
          note: string | null
          person_id: string
          requires_document: boolean
          start_date: string
          status: string
          submitted_by: string | null
          updated_at: string
          working_days: number
        }
        Insert: {
          cancellation_decline_note?: string | null
          cancellation_declined_at?: string | null
          cancellation_declined_by?: string | null
          cancellation_reason?: string | null
          cancellation_request_reason?: string | null
          cancellation_requested_at?: string | null
          cancelled_at?: string | null
          cancelled_by?: string | null
          carry_over_days_used?: number
          company_id: string
          corrected_from_id?: string | null
          created_at?: string
          decided_at?: string | null
          decided_by?: string | null
          decision_note?: string | null
          deducts_balance: boolean
          documents_to_follow?: boolean
          employment_period_id: string
          end_date: string
          id?: string
          leave_type_key: string
          legacy_id?: number | null
          note?: string | null
          person_id: string
          requires_document: boolean
          start_date: string
          status?: string
          submitted_by?: string | null
          updated_at?: string
          working_days: number
        }
        Update: {
          cancellation_decline_note?: string | null
          cancellation_declined_at?: string | null
          cancellation_declined_by?: string | null
          cancellation_reason?: string | null
          cancellation_request_reason?: string | null
          cancellation_requested_at?: string | null
          cancelled_at?: string | null
          cancelled_by?: string | null
          carry_over_days_used?: number
          company_id?: string
          corrected_from_id?: string | null
          created_at?: string
          decided_at?: string | null
          decided_by?: string | null
          decision_note?: string | null
          deducts_balance?: boolean
          documents_to_follow?: boolean
          employment_period_id?: string
          end_date?: string
          id?: string
          leave_type_key?: string
          legacy_id?: number | null
          note?: string | null
          person_id?: string
          requires_document?: boolean
          start_date?: string
          status?: string
          submitted_by?: string | null
          updated_at?: string
          working_days?: number
        }
        Relationships: [
          {
            foreignKeyName: "leave_requests_cancellation_declined_by_fkey"
            columns: ["cancellation_declined_by"]
            isOneToOne: false
            referencedRelation: "people"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "leave_requests_cancelled_by_fkey"
            columns: ["cancelled_by"]
            isOneToOne: false
            referencedRelation: "people"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "leave_requests_company_id_fkey"
            columns: ["company_id"]
            isOneToOne: false
            referencedRelation: "companies"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "leave_requests_corrected_from_id_fkey"
            columns: ["corrected_from_id"]
            isOneToOne: false
            referencedRelation: "leave_requests"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "leave_requests_decided_by_fkey"
            columns: ["decided_by"]
            isOneToOne: false
            referencedRelation: "people"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "leave_requests_employment_period_id_fkey"
            columns: ["employment_period_id"]
            isOneToOne: false
            referencedRelation: "employment_periods"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "leave_requests_leave_type_key_fkey"
            columns: ["leave_type_key"]
            isOneToOne: false
            referencedRelation: "leave_types"
            referencedColumns: ["key"]
          },
          {
            foreignKeyName: "leave_requests_person_id_fkey"
            columns: ["person_id"]
            isOneToOne: false
            referencedRelation: "people"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "leave_requests_submitted_by_fkey"
            columns: ["submitted_by"]
            isOneToOne: false
            referencedRelation: "people"
            referencedColumns: ["id"]
          },
        ]
      }
      leave_types: {
        Row: {
          deducts_balance: boolean
          is_active: boolean
          key: string
          label: string
          requires_document: boolean
          sort_order: number
        }
        Insert: {
          deducts_balance?: boolean
          is_active?: boolean
          key: string
          label: string
          requires_document?: boolean
          sort_order?: number
        }
        Update: {
          deducts_balance?: boolean
          is_active?: boolean
          key?: string
          label?: string
          requires_document?: boolean
          sort_order?: number
        }
        Relationships: []
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
      notifications: {
        Row: {
          body: string | null
          company_id: string | null
          created_at: string
          dedupe_key: string
          email_attempts: number
          email_error: string | null
          email_sent_at: string | null
          email_status: string
          email_to: string | null
          entity_id: string | null
          entity_type: string | null
          id: string
          kind: string
          link: string | null
          person_id: string
          read_at: string | null
          title: string
        }
        Insert: {
          body?: string | null
          company_id?: string | null
          created_at?: string
          dedupe_key: string
          email_attempts?: number
          email_error?: string | null
          email_sent_at?: string | null
          email_status?: string
          email_to?: string | null
          entity_id?: string | null
          entity_type?: string | null
          id?: string
          kind: string
          link?: string | null
          person_id: string
          read_at?: string | null
          title: string
        }
        Update: {
          body?: string | null
          company_id?: string | null
          created_at?: string
          dedupe_key?: string
          email_attempts?: number
          email_error?: string | null
          email_sent_at?: string | null
          email_status?: string
          email_to?: string | null
          entity_id?: string | null
          entity_type?: string | null
          id?: string
          kind?: string
          link?: string | null
          person_id?: string
          read_at?: string | null
          title?: string
        }
        Relationships: [
          {
            foreignKeyName: "notifications_company_id_fkey"
            columns: ["company_id"]
            isOneToOne: false
            referencedRelation: "companies"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "notifications_person_id_fkey"
            columns: ["person_id"]
            isOneToOne: false
            referencedRelation: "people"
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
          created_by: string | null
          decline_reason: string | null
          extended_at: string | null
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
          created_by?: string | null
          decline_reason?: string | null
          extended_at?: string | null
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
          created_by?: string | null
          decline_reason?: string | null
          extended_at?: string | null
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
          {
            foreignKeyName: "offers_created_by_fkey"
            columns: ["created_by"]
            isOneToOne: false
            referencedRelation: "people"
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
      payroll_items: {
        Row: {
          amount: number
          company_id: string
          created_at: string
          created_by: string | null
          currency: string
          id: string
          item_date: string
          period_id: string | null
          person_id: string
          reason: string
        }
        Insert: {
          amount: number
          company_id: string
          created_at?: string
          created_by?: string | null
          currency: string
          id?: string
          item_date?: string
          period_id?: string | null
          person_id: string
          reason: string
        }
        Update: {
          amount?: number
          company_id?: string
          created_at?: string
          created_by?: string | null
          currency?: string
          id?: string
          item_date?: string
          period_id?: string | null
          person_id?: string
          reason?: string
        }
        Relationships: [
          {
            foreignKeyName: "payroll_items_company_id_fkey"
            columns: ["company_id"]
            isOneToOne: false
            referencedRelation: "companies"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "payroll_items_period_id_fkey"
            columns: ["period_id"]
            isOneToOne: false
            referencedRelation: "payroll_periods"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "payroll_items_person_id_fkey"
            columns: ["person_id"]
            isOneToOne: false
            referencedRelation: "people"
            referencedColumns: ["id"]
          },
        ]
      }
      payroll_lines: {
        Row: {
          amount: number
          bonus: number
          company_id: string
          compensation_record_id: string | null
          created_at: string
          currency: string
          days_covered: number
          deductions: number
          effective_from: string
          effective_to: string
          employment_period_id: string
          full_name: string
          gross: number
          id: string
          job_title: string
          net: number
          pay_basis_key: string
          period_id: string
          person_id: string
          tax: number
        }
        Insert: {
          amount: number
          bonus?: number
          company_id: string
          compensation_record_id?: string | null
          created_at?: string
          currency: string
          days_covered: number
          deductions?: number
          effective_from: string
          effective_to: string
          employment_period_id: string
          full_name: string
          gross?: number
          id?: string
          job_title: string
          net?: number
          pay_basis_key: string
          period_id: string
          person_id: string
          tax?: number
        }
        Update: {
          amount?: number
          bonus?: number
          company_id?: string
          compensation_record_id?: string | null
          created_at?: string
          currency?: string
          days_covered?: number
          deductions?: number
          effective_from?: string
          effective_to?: string
          employment_period_id?: string
          full_name?: string
          gross?: number
          id?: string
          job_title?: string
          net?: number
          pay_basis_key?: string
          period_id?: string
          person_id?: string
          tax?: number
        }
        Relationships: [
          {
            foreignKeyName: "payroll_lines_company_id_fkey"
            columns: ["company_id"]
            isOneToOne: false
            referencedRelation: "companies"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "payroll_lines_compensation_record_id_fkey"
            columns: ["compensation_record_id"]
            isOneToOne: false
            referencedRelation: "compensation_records"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "payroll_lines_employment_period_id_fkey"
            columns: ["employment_period_id"]
            isOneToOne: false
            referencedRelation: "employment_periods"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "payroll_lines_period_id_fkey"
            columns: ["period_id"]
            isOneToOne: false
            referencedRelation: "payroll_periods"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "payroll_lines_person_id_fkey"
            columns: ["person_id"]
            isOneToOne: false
            referencedRelation: "people"
            referencedColumns: ["id"]
          },
        ]
      }
      payroll_periods: {
        Row: {
          approved_by: string | null
          company_id: string
          created_at: string
          currency: string
          deductions_flat: number | null
          export_document_id: string | null
          exported_at: string | null
          id: string
          note: string | null
          period_end: string
          period_start: string
          prepared_at: string | null
          prepared_by: string | null
          reopened_at: string | null
          status: string
          tax_rate_percent: number | null
          updated_at: string
        }
        Insert: {
          approved_by?: string | null
          company_id: string
          created_at?: string
          currency: string
          deductions_flat?: number | null
          export_document_id?: string | null
          exported_at?: string | null
          id?: string
          note?: string | null
          period_end: string
          period_start: string
          prepared_at?: string | null
          prepared_by?: string | null
          reopened_at?: string | null
          status?: string
          tax_rate_percent?: number | null
          updated_at?: string
        }
        Update: {
          approved_by?: string | null
          company_id?: string
          created_at?: string
          currency?: string
          deductions_flat?: number | null
          export_document_id?: string | null
          exported_at?: string | null
          id?: string
          note?: string | null
          period_end?: string
          period_start?: string
          prepared_at?: string | null
          prepared_by?: string | null
          reopened_at?: string | null
          status?: string
          tax_rate_percent?: number | null
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
          {
            foreignKeyName: "payroll_periods_prepared_by_fkey"
            columns: ["prepared_by"]
            isOneToOne: false
            referencedRelation: "people"
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
          bank_account: Json | null
          birth_date: string | null
          custom: Json
          emergency_contacts: Json
          national_id: string | null
          national_id_hint: string | null
          notes: string | null
          person_id: string
          updated_at: string
        }
        Insert: {
          address?: Json | null
          bank_account?: Json | null
          birth_date?: string | null
          custom?: Json
          emergency_contacts?: Json
          national_id?: string | null
          national_id_hint?: string | null
          notes?: string | null
          person_id: string
          updated_at?: string
        }
        Update: {
          address?: Json | null
          bank_account?: Json | null
          birth_date?: string | null
          custom?: Json
          emergency_contacts?: Json
          national_id?: string | null
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
          asset_id: string | null
          task_key: string | null
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
          asset_id?: string | null
          task_key?: string | null
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
          asset_id?: string | null
          task_key?: string | null
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
            foreignKeyName: "plan_tasks_asset_id_fkey"
            columns: ["asset_id"]
            isOneToOne: false
            referencedRelation: "assets"
            referencedColumns: ["id"]
          },
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
          welcome_sent_at: string | null
          welcome_sent_to: string | null
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
          welcome_sent_at?: string | null
          welcome_sent_to?: string | null
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
          welcome_sent_at?: string | null
          welcome_sent_to?: string | null
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
          body: string | null
          company_id: string | null
          created_at: string
          id: string
          mime_type: string | null
          original_name: string | null
          published_at: string | null
          published_by: string | null
          status: string
          storage_path: string | null
          summary: string | null
          title: string
          updated_at: string
          version: number
        }
        Insert: {
          body?: string | null
          company_id?: string | null
          created_at?: string
          id?: string
          mime_type?: string | null
          original_name?: string | null
          published_at?: string | null
          published_by?: string | null
          status?: string
          storage_path?: string | null
          summary?: string | null
          title: string
          updated_at?: string
          version?: number
        }
        Update: {
          body?: string | null
          company_id?: string | null
          created_at?: string
          id?: string
          mime_type?: string | null
          original_name?: string | null
          published_at?: string | null
          published_by?: string | null
          status?: string
          storage_path?: string | null
          summary?: string | null
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
          drafted_by: string | null
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
          drafted_by?: string | null
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
          drafted_by?: string | null
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
            foreignKeyName: "promotions_drafted_by_fkey"
            columns: ["drafted_by"]
            isOneToOne: false
            referencedRelation: "people"
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
      public_holidays: {
        Row: {
          country_code: string
          created_at: string
          date: string
          id: string
          kind: string
          name: string
          observed_of: string | null
        }
        Insert: {
          country_code: string
          created_at?: string
          date: string
          id?: string
          kind?: string
          name: string
          observed_of?: string | null
        }
        Update: {
          country_code?: string
          created_at?: string
          date?: string
          id?: string
          kind?: string
          name?: string
          observed_of?: string | null
        }
        Relationships: []
      }
      scorecards: {
        Row: {
          application_id: string
          author_id: string
          company_id: string
          id: string
          interview_id: string
          ratings: Json
          recommendation: string
          submitted_at: string
          summary: string | null
          updated_at: string
        }
        Insert: {
          application_id: string
          author_id: string
          company_id: string
          id?: string
          interview_id: string
          ratings?: Json
          recommendation: string
          submitted_at?: string
          summary?: string | null
          updated_at?: string
        }
        Update: {
          application_id?: string
          author_id?: string
          company_id?: string
          id?: string
          interview_id?: string
          ratings?: Json
          recommendation?: string
          submitted_at?: string
          summary?: string | null
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "scorecards_application_id_fkey"
            columns: ["application_id"]
            isOneToOne: false
            referencedRelation: "applications"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "scorecards_author_id_fkey"
            columns: ["author_id"]
            isOneToOne: false
            referencedRelation: "people"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "scorecards_company_id_fkey"
            columns: ["company_id"]
            isOneToOne: false
            referencedRelation: "companies"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "scorecards_interview_id_fkey"
            columns: ["interview_id"]
            isOneToOne: false
            referencedRelation: "interviews"
            referencedColumns: ["id"]
          },
        ]
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
          archived_at: string | null
          critical: boolean
          default_owner_role: string
          description: string | null
          due_offset_days: number
          id: string
          key: string | null
          phase_key: string
          requires_evidence: boolean
          sort_order: number
          template_id: string
          title: string
        }
        Insert: {
          archived_at?: string | null
          critical?: boolean
          default_owner_role?: string
          description?: string | null
          due_offset_days?: number
          id?: string
          key?: string | null
          phase_key: string
          requires_evidence?: boolean
          sort_order?: number
          template_id: string
          title: string
        }
        Update: {
          archived_at?: string | null
          critical?: boolean
          default_owner_role?: string
          description?: string | null
          due_offset_days?: number
          id?: string
          key?: string | null
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
      acknowledge_policy: { Args: { p_policy_id: string }; Returns: Json }
      add_plan_task: {
        Args: {
          p_critical?: boolean
          p_due_date?: string
          p_owner_role?: string
          p_plan_id: string
          p_title: string
        }
        Returns: Json
      }
      add_kit_item: { Args: { p_item: string; p_request_id: string }; Returns: Json }
      adjust_leave_balance: {
        Args: {
          p_company_id: string
          p_days: number
          p_person_id: string
          p_reason: string
          p_year: number
        }
        Returns: Json
      }
      advance_it_request: {
        Args: {
          p_assignee_id?: string
          p_blocked_reason?: string
          p_request_id: string
          p_status: string
        }
        Returns: Json
      }
      advance_offer: {
        Args: { p_offer_id: string; p_reason?: string; p_to_status: string }
        Returns: Json
      }
      advance_promotion: {
        Args: {
          p_brief?: Json
          p_copy?: string
          p_promotion_id: string
          p_publication_url?: string
          p_to_status: string
        }
        Returns: Json
      }
      apply_due_employment_changes: { Args: never; Returns: number }
      approve_payroll_period: { Args: { p_period_id: string }; Returns: Json }
      archive_company: { Args: { p_company_id: string }; Returns: Json }
      archive_policy: { Args: { p_policy_id: string }; Returns: Json }
      attach_leave_document: {
        Args: { p_document_id: string; p_request_id: string }
        Returns: Json
      }
      cancel_departure: {
        Args: { p_employment_period_id: string; p_reason?: string }
        Returns: Json
      }
      cancel_employment_change: {
        Args: { p_change_id: string }
        Returns: undefined
      }
      cancel_leave: {
        Args: { p_reason: string; p_request_id: string }
        Returns: Json
      }
      cancel_reservation: { Args: { p_assignment_id: string }; Returns: Json }
      compensation_summary: { Args: { p_company_id: string }; Returns: Json }
      company_template: {
        Args: { p_company_id: string; p_kind: string }
        Returns: Json
      }
      complete_departure: {
        Args: { p_employment_period_id: string }
        Returns: Json
      }
      confirm_hire: {
        Args: {
          p_application_id: string
          p_full_name: string
          p_job_title: string
          p_manager_id?: string
          p_start_date: string
        }
        Returns: Json
      }
      correct_employment: {
        Args: {
          p_employment_type_key?: string
          p_fields?: Json
          p_job_title?: string
          p_period_id: string
          p_reason?: string
          p_start_date: string
        }
        Returns: Json
      }
      correct_leave: {
        Args: { p_days: Json; p_note?: string; p_request_id: string }
        Returns: Json
      }
      create_employee: { Args: { p: Json }; Returns: Json }
      dashboard_snapshot: { Args: { p_days?: number }; Returns: Json }
      decide_compensation: {
        Args: { p_decision: string; p_note?: string; p_record_id: string }
        Returns: Json
      }
      decide_leave: {
        Args: { p_decision: string; p_note?: string; p_request_id: string }
        Returns: Json
      }
      decline_leave_cancellation: {
        Args: { p_note: string; p_request_id: string }
        Returns: Json
      }
      first_day_details: { Args: { p_company_id: string }; Returns: Json }
      add_payroll_item: { Args: { p: Json }; Returns: Json }
      remove_payroll_item: { Args: { p_id: string }; Returns: Json }
      payroll_settings: { Args: { p_company_id: string }; Returns: Json }
      set_payroll_settings: { Args: { p: Json; p_company_id: string }; Returns: Json }
      kudos_overview: { Args: { p_month?: string | null }; Returns: Json }
      record_kudos: { Args: { p: Json }; Returns: Json }
      update_kudos: { Args: { p: Json; p_id: string }; Returns: Json }
      save_kudos_value: { Args: { p: Json; p_id: string | null }; Returns: Json }
      handover_fields: { Args: never; Returns: Json }
      import_field_notebook: {
        Args: { p_commit?: boolean; p_payload: Json }
        Returns: Json
      }
      import_people: {
        Args: { p_commit?: boolean; p_company_id: string; p_rows: Json }
        Returns: Json
      }
      issue_asset: { Args: { p_assignment_id: string }; Returns: Json }
      issue_kit_item: {
        Args: { p_asset_id?: string; p_index: number; p_request_id: string }
        Returns: Json
      }
      leave_balance: {
        Args: { p_company_id: string; p_person_id: string; p_year: number }
        Returns: Json
      }
      mark_handover_sent: { Args: { p_id: string }; Returns: Json }
      mark_notifications_read: { Args: { p_ids?: string[] }; Returns: number }
      mark_payroll_exported: { Args: { p_period_id: string }; Returns: Json }
      prepare_payroll_period: {
        Args: {
          p_company_id: string
          p_currency: string
          p_end: string
          p_note?: string
          p_start: string
        }
        Returns: Json
      }
      propose_compensation: {
        Args: {
          p_amount: number
          p_currency: string
          p_effective_date: string
          p_note?: string
          p_pay_basis_key: string
          p_period_id: string
        }
        Returns: Json
      }
      publish_policy: {
        Args: {
          p_body?: string
          p_mime_type?: string
          p_original_name?: string
          p_policy_id: string
          p_storage_path?: string
        }
        Returns: Json
      }
      recruitment_report: {
        Args: { p_company_id: string; p_from: string; p_to: string }
        Returns: Json
      }
      reopen_payroll_period: { Args: { p_period_id: string }; Returns: Json }
      request_leave: {
        Args: {
          p_documents_to_follow?: boolean
          p_end: string
          p_leave_type_key: string
          p_note?: string
          p_person_id: string
          p_record_as_approved?: boolean
          p_start: string
        }
        Returns: Json
      }
      request_leave_cancellation: {
        Args: { p_reason: string; p_request_id: string }
        Returns: Json
      }
      requestable_leave: {
        Args: {
          p_company_id: string
          p_end: string
          p_person_id: string
          p_start: string
        }
        Returns: number
      }
      reserve_asset: {
        Args: { p_asset_id: string; p_note?: string; p_person_id: string }
        Returns: Json
      }
      return_asset: {
        Args: {
          p_assignment_id: string
          p_condition?: string
          p_status?: string
        }
        Returns: Json
      }
      review_document_request: {
        Args: { p_decision: string; p_note?: string; p_request_id: string }
        Returns: Json
      }
      roll_leave_year: { Args: { p_year: number }; Returns: number }
      remove_handover_recipient: { Args: { p_id: string }; Returns: Json }
      reorder_template_tasks: {
        Args: { p_ids: string[]; p_template_id: string }
        Returns: Json
      }
      resend_handover: { Args: { p_id: string }; Returns: Json }
      retire_template_task: { Args: { p_id: string }; Returns: Json }
      retry_handover: { Args: { p_id: string }; Returns: Json }
      save_handover_recipient: { Args: { p: Json }; Returns: Json }
      schedule_departure: {
        Args: {
          p_employment_period_id: string
          p_end_date: string
          p_last_working_date?: string
          p_reason?: string
        }
        Returns: Json
      }
      schedule_employment_change: {
        Args: {
          p_changes: Json
          p_effective_date: string
          p_period_id: string
          p_reason?: string
        }
        Returns: Json
      }
      set_avatar: {
        Args: { p_path?: string; p_person_id: string }
        Returns: Json
      }
      send_welcome_note: { Args: { p_plan_id: string; p_to?: string }; Returns: Json }
      set_first_day_details: { Args: { p: Json; p_company_id: string }; Returns: Json }
      set_starter_kit: { Args: { p_company_id: string; p_items: string[] }; Returns: Json }
      starter_kit: { Args: { p_company_id: string }; Returns: Json }
      set_leave_entitlement: {
        Args: {
          p_company_id: string
          p_entitlement: number
          p_person_id: string
          p_reason: string
          p_year: number
        }
        Returns: Json
      }
      submit_requested_document: {
        Args: { p_document_id: string; p_request_id: string }
        Returns: Json
      }
      team_leave: {
        Args: { p_company_id: string; p_from: string; p_to: string }
        Returns: Json
      }
      transfer_employment: {
        Args: {
          p_company_id: string
          p_effective_date: string
          p_employment_type_key?: string
          p_job_title?: string
          p_period_id: string
          p_reason?: string
        }
        Returns: Json
      }
      upsert_template_task: { Args: { p: Json }; Returns: Json }
      welcome_note_text: { Args: { p_plan_id: string }; Returns: Json }
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

