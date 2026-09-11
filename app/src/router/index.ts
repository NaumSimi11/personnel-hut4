import { createRouter, createWebHistory } from 'vue-router'
import { useAuthStore } from '@/stores/auth'

export const router = createRouter({
  history: createWebHistory(),
  routes: [
    {
      path: '/login',
      name: 'login',
      component: () => import('@/pages/LoginPage.vue'),
      meta: { public: true },
    },
    {
      path: '/change-password',
      name: 'change-password',
      component: () => import('@/pages/ChangePasswordPage.vue'),
    },
    // The public careers pages (plan 019): no sign-in, no app shell, and
    // no Supabase access — they read and submit through the auth service.
    {
      path: '/careers/:code',
      name: 'careers-company',
      component: () => import('@/pages/CareersCompanyPage.vue'),
      meta: { public: true },
    },
    {
      path: '/careers/:code/:jobId',
      name: 'careers-job',
      component: () => import('@/pages/CareersJobPage.vue'),
      meta: { public: true },
    },
    {
      path: '/',
      component: () => import('@/components/AppShell.vue'),
      children: [
        { path: '', redirect: { name: 'overview' } },
        {
          path: 'overview',
          name: 'overview',
          component: () => import('@/pages/HomePage.vue'),
        },
        {
          path: 'companies',
          name: 'companies',
          component: () => import('@/pages/CompaniesPage.vue'),
        },
        {
          // Static segment before the :companyId param so "new" is never an id.
          path: 'companies/new',
          name: 'company-new',
          component: () => import('@/pages/CompanyFormPage.vue'),
        },
        {
          path: 'companies/:companyId',
          name: 'company',
          component: () => import('@/pages/CompanyProfilePage.vue'),
        },
        {
          path: 'companies/:companyId/edit',
          name: 'company-edit',
          component: () => import('@/pages/CompanyFormPage.vue'),
        },
        {
          path: 'directory',
          name: 'directory',
          component: () => import('@/pages/DirectoryPage.vue'),
        },
        {
          path: 'hiring',
          name: 'hiring',
          component: () => import('@/pages/HiringRequestsPage.vue'),
        },
        {
          path: 'hiring/jobs/:jobId',
          name: 'job',
          component: () => import('@/pages/JobPage.vue'),
        },
        {
          path: 'hiring/applications/:applicationId',
          name: 'application',
          component: () => import('@/pages/ApplicationPage.vue'),
        },
        {
          path: 'reports',
          name: 'reports',
          component: () => import('@/pages/ReportsPage.vue'),
        },
        {
          path: 'onboarding',
          name: 'onboarding',
          component: () => import('@/pages/OnboardingPage.vue'),
        },
        {
          path: 'onboarding/:planId',
          name: 'onboarding-plan',
          component: () => import('@/pages/OnboardingPlanPage.vue'),
        },
        {
          path: 'offboarding',
          name: 'offboarding',
          component: () => import('@/pages/OffboardingPage.vue'),
        },
        {
          // Same plan detail component; it switches labels and the finish
          // action on plan.kind.
          path: 'offboarding/:planId',
          name: 'offboarding-plan',
          component: () => import('@/pages/OnboardingPlanPage.vue'),
        },
        {
          path: 'people/:personId',
          name: 'person',
          component: () => import('@/pages/PersonProfilePage.vue'),
        },
        {
          path: 'people/:personId/access',
          name: 'access-editor',
          component: () => import('@/pages/AccessEditorPage.vue'),
        },
        {
          path: 'me',
          name: 'my-workspace',
          component: () => import('@/pages/MyWorkspacePage.vue'),
        },
      ],
    },
    { path: '/:pathMatch(.*)*', redirect: '/' },
  ],
})

router.beforeEach(async (to) => {
  const auth = useAuthStore()
  await auth.init()
  if (!to.meta.public && !auth.isAuthenticated) return { name: 'login' }
  // A temp-password session may only see the change-password screen. The
  // database refuses everything else anyway (RLS reads the same flag); this
  // redirect is the convenience, not the control.
  if (auth.isAuthenticated && auth.mustChangePassword && to.name !== 'change-password') {
    return { name: 'change-password' }
  }
  if (auth.isAuthenticated && !auth.mustChangePassword && to.name === 'change-password') {
    return { name: 'overview' }
  }
  if (to.name === 'login' && auth.isAuthenticated) return { name: 'overview' }
  return true
})
